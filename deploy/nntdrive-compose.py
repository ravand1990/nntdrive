#!/usr/bin/env python3
"""Linux/WSL image-only Compose launcher. Never rotate deployment credentials."""
import argparse
import base64
import binascii
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote


class BootstrapError(Exception):
    pass


def checked(command, env=None, input_text=None):
    # Compose diagnostics/config can contain interpolated secrets. Keep them private,
    # including failures; callers may explicitly print only non-sensitive results.
    result = subprocess.run(command, env=env, input=input_text, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise BootstrapError("Docker/Compose command failed; check Docker access, configuration and image availability (diagnostics suppressed).")
    return result.stdout


def validate(password, key):
    if not isinstance(password, str) or not password or any(ord(c) < 32 or ord(c) == 127 for c in password):
        raise BootstrapError("Invalid database password; expected a nonempty single-line value.")
    try:
        if not isinstance(key, str):
            raise ValueError()
        decoded = base64.b64decode(key, validate=True)
        if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != key:
            raise ValueError()
    except (ValueError, binascii.Error):
        raise BootstrapError("Invalid provider secret; expected base64 encoding of 32 bytes.") from None


def protected(path, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600):
        raise BootstrapError("Secret storage must be owned by this user, not linked, and mode 0700 (directory) / 0600 (files); restore protected storage manually.")
    if not directory and info.st_nlink != 1:
        raise BootstrapError("Linked secret storage refused.")


def initialize(directory, project, password, key, existing_resources):
    """Called under the launcher's lock; also serializes independent initializers."""
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    protected(directory, directory=True)
    lock_fd = os.open(directory / "lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock_fd, "r+") as lock:
        protected(directory / "lock")
        fcntl.flock(lock, fcntl.LOCK_EX)
        path = directory / "secrets.json"
        if os.path.lexists(path):
            protected(path)
            try:
                stored = json.loads(path.read_text())
                if stored["version"] != 1 or stored["project"] != project:
                    raise ValueError()
                validate(stored["password"], stored["key"])
            except (KeyError, TypeError, ValueError, BootstrapError):
                raise BootstrapError("Secret file is corrupt or belongs to another project; restore its backup, never regenerate it.") from None
            if (password and password != stored["password"]) or (key and key != stored["key"]):
                raise BootstrapError("Explicit credentials differ from saved credentials; rotation is not supported. Restore the original configuration.")
            return stored
        # Refuse even with two explicit values: adopting existing installations is
        # a separate migration, not an implicit first-boot operation.
        if existing_resources():
            raise BootstrapError("Secret file is missing but project volumes/containers exist. Restore the original secret backup; automatic initialization refused.")
        stored = {"version": 1, "project": project,
                  "password": password or secrets.token_hex(32),
                  "key": key or base64.b64encode(secrets.token_bytes(32)).decode("ascii")}
        validate(stored["password"], stored["key"])
        fd, pending = tempfile.mkstemp(prefix=".pending-", dir=directory)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(stored, stream)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            # Atomic create-only publication: never replace another secret file.
            os.link(pending, path)
        finally:
            os.unlink(pending)
        dir_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
        return stored


def secret_environment(stored):
    return {**os.environ, "POSTGRES_PASSWORD": stored["password"],
            "NNTDRIVE_SECRET_KEY": stored["key"],
            "NNTDRIVE_DATABASE_URL": "postgres://nntdrive:" + quote(stored["password"], safe="") + "@postgres:5432/nntdrive"}


def resolve_explicit(base):
    # Compose owns dotenv quoting/interpolation and environment precedence.
    model = {"services": {"resolve": {"image": "postgres:16-alpine", "environment": {
        "POSTGRES_PASSWORD": "${POSTGRES_PASSWORD:-}", "NNTDRIVE_SECRET_KEY": "${NNTDRIVE_SECRET_KEY:-}"}}}}
    resolved = json.loads(checked(base + ["-f", "-", "config", "--format", "json"], input_text=json.dumps(model)))
    # `config` serializes a reusable Compose model, escaping literal dollars
    # as $$ even in JSON. Undo that serialization, not dotenv interpolation.
    return {key: value.replace("$$", "$") for key, value in resolved["services"]["resolve"]["environment"].items()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-name", default="nntdrive")
    parser.add_argument("--profile", choices=["tls"])
    parser.add_argument("--force-recreate", action="store_true")
    parser.add_argument("command", choices=["up", "pull", "down", "restart", "stop", "start", "ps", "exec", "cp"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.arguments and args.command not in ("exec", "cp"):
        if args.command not in ("start", "stop", "restart") or any(service not in ("backend", "postgres", "caddy") for service in args.arguments):
            parser.error("Only exec/cp accept arbitrary trailing arguments; start/stop/restart accept release service names.")
    if args.force_recreate and args.command != "up":
        parser.error("--force-recreate requires up")
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", args.project_name):
        raise BootstrapError("Invalid Compose project name.")
    directory = Path(__file__).resolve().parent
    env_file = directory / ".env"
    base = ["docker", "compose", "--project-directory", str(directory), "--project-name", args.project_name,
            "--env-file", str(env_file) if env_file.exists() else "/dev/null"]
    # Let Compose (not a second dotenv parser or shell 'source') resolve explicit
    # .env/environment values. This tiny model contains no deployment resources.
    explicit = resolve_explicit(base)

    def existing_resources():
        # Fail closed if Docker cannot be queried. Match actual fixed release
        # volume names AND labels, including stopped containers and empty volumes.
        names = set(checked(["docker", "volume", "ls", "--format", "{{.Name}}"]).splitlines())
        expected = {args.project_name + "_" + name for name in ("nntdrive-pg", "nntdrive-cache", "caddy-data", "caddy-config")}
        labeled = checked(["docker", "volume", "ls", "-q", "--filter", "label=com.docker.compose.project=" + args.project_name])
        containers = checked(["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project=" + args.project_name])
        return bool(names & expected or labeled.strip() or containers.strip())

    state = initialize(directory / ".nntdrive-secrets", args.project_name,
                       explicit.get("POSTGRES_PASSWORD") or "", explicit.get("NNTDRIVE_SECRET_KEY") or "", existing_resources)
    command = base + ["-f", str(directory / "docker-compose.release.yml")]
    if args.profile:
        command += ["--profile", args.profile]
    command += [args.command]
    if args.command == "up":
        command += ["-d", "--wait"]
        if args.force_recreate:
            command += ["--force-recreate"]
    command += args.arguments
    # No config/logs passthrough: config exposes deployment credentials. exec/cp
    # are explicit trusted operator actions, not secret-disclosure sandboxes.
    if args.command in ("exec", "cp"):
        # Explicit operator commands may produce binary dumps or interactive
        # prompts. Do not buffer/transform their data or add anything to stdout.
        # Such commands are trusted code, not a sandbox for secret inspection.
        result = subprocess.run(command, env=secret_environment(state))
        if result.returncode:
            raise BootstrapError("Compose operator command failed.")
        return
    output = checked(command, secret_environment(state))
    for value in (state["password"], state["key"], quote(state["password"], safe="")):
        output = output.replace(value, "[redacted]")
    print(output, end="")
    print("Compose command completed; deployment credentials retained in .nntdrive-secrets/.")


if __name__ == "__main__":
    try:
        main()
    except BootstrapError as error:
        print("Deployment refused: " + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError):
        # Do not echo raw exceptions: OS/Compose/JSON errors can contain secrets.
        print("Deployment refused: check protected secret storage and Docker configuration; restore original secrets if data exists, never delete them to retry.", file=sys.stderr)
        sys.exit(1)
