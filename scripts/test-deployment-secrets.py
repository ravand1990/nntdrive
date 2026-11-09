#!/usr/bin/env python3
"""Filesystem security regressions; no simulated Docker daemon or stack."""
import base64
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("deployment", ROOT / "deploy/nntdrive-compose.py")
assert spec is not None and spec.loader is not None
deployment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deployment)


class Secrets(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name) / "private"

    def initialize(self, password="", key="", exists=False, project="unit"):
        return deployment.initialize(self.directory, project, password, key, lambda: exists)

    def test_generate_reuse_permissions_and_randomness(self):
        first = self.initialize()
        saved = (self.directory / "secrets.json").read_bytes()
        self.assertEqual(len(base64.b64decode(first["key"], validate=True)), 32)
        self.assertEqual(len(first["password"]), 64)
        for _ in range(3):
            self.assertEqual(self.initialize(exists=True), first)
            self.assertEqual((self.directory / "secrets.json").read_bytes(), saved)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.directory / "secrets.json").stat().st_mode & 0o777, 0o600)
        self.assertNotEqual(deployment.initialize(Path(self.temp.name) / "other", "unit", "", "", lambda: False), first)

    def test_explicit_either_both_and_no_rotation(self):
        key = base64.b64encode(bytes(range(32))).decode()
        for index, (password, supplied_key) in enumerate([("p@$:' word", ""), ("", key), ("explicit", key)]):
            directory = Path(self.temp.name) / str(index)
            result = deployment.initialize(directory, "unit", password, supplied_key, lambda: False)
            self.assertEqual(result["password"] if password else result["key"], password or key)
            self.assertEqual(deployment.initialize(directory, "unit", password, supplied_key, lambda: True), result)
            before = (directory / "secrets.json").read_bytes()
            with self.assertRaises(deployment.BootstrapError):
                deployment.initialize(directory, "unit", "different", "", lambda: True)
            self.assertEqual((directory / "secrets.json").read_bytes(), before)

    def test_existing_data_missing_file_even_explicit_refuses(self):
        for password in ("", "explicit"):
            with self.assertRaises(deployment.BootstrapError):
                self.initialize(password=password, exists=True)
            self.assertFalse((self.directory / "secrets.json").exists())

    def test_empty_corrupt_partial_invalid_and_project_refuse_unchanged(self):
        self.initialize()
        path = self.directory / "secrets.json"
        valid = json.loads(path.read_text())
        for content in ("", "{", "{}", json.dumps({**valid, "key": "invalid"}), json.dumps({**valid, "password": ""}), json.dumps({**valid, "project": "other"})):
            path.write_text(content)
            with self.assertRaises(deployment.BootstrapError):
                self.initialize()
            self.assertEqual(path.read_text(), content)

    def test_invalid_explicit_does_not_publish(self):
        for key in ("bad", base64.b64encode(b"short").decode()):
            with self.assertRaises(deployment.BootstrapError):
                self.initialize(key=key)
            self.assertFalse((self.directory / "secrets.json").exists())

    def test_symlinks_and_unsafe_permissions_refuse(self):
        target = Path(self.temp.name) / "target"
        target.mkdir(mode=0o700)
        self.directory.symlink_to(target, target_is_directory=True)
        with self.assertRaises(deployment.BootstrapError):
            self.initialize()
        self.directory.unlink()
        self.initialize()
        path = self.directory / "secrets.json"
        path.chmod(0o644)
        with self.assertRaises(deployment.BootstrapError):
            self.initialize()
        path.unlink()
        path.symlink_to(target / "absent")
        with self.assertRaises(deployment.BootstrapError):
            self.initialize()
        self.assertFalse((target / "absent").exists())

    def test_interrupted_publish_is_never_partial(self):
        with patch.object(deployment.os, "link", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.initialize()
        self.assertFalse((self.directory / "secrets.json").exists())
        self.assertEqual(list(self.directory.glob(".pending-*")), [])
        self.initialize()

    def test_interruption_before_flush_and_after_publication_fail_closed(self):
        with patch.object(deployment.os, "fsync", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.initialize()
        self.assertFalse((self.directory / "secrets.json").exists())
        with patch.object(deployment.os, "unlink", side_effect=OSError("interrupted")):
            with self.assertRaises(OSError):
                self.initialize()
        # A crash between link and unlink leaves a complete but multiply-linked
        # file. Refuse it rather than adopt/regenerate ambiguous credentials.
        path = self.directory / "secrets.json"
        before = path.read_bytes()
        with self.assertRaises(deployment.BootstrapError):
            self.initialize(exists=True)
        self.assertEqual(path.read_bytes(), before)

    def test_concurrent_processes_generate_only_once(self):
        code = 'import hashlib,importlib.util,json,sys; from pathlib import Path; s=importlib.util.spec_from_file_location("d",sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); r=m.initialize(Path(sys.argv[2]),"unit","","",lambda:False); print(hashlib.sha256(json.dumps(r,sort_keys=True).encode()).hexdigest())'
        def run(_):
            return subprocess.run([sys.executable, "-B", "-c", code, str(ROOT / "deploy/nntdrive-compose.py"), str(self.directory)], capture_output=True)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(run, range(16)))
        # Harness-only digests prove every process received the SAME credentials
        # without sending the credentials themselves to stdout or test logs.
        self.assertTrue(all(r.returncode == 0 and len(r.stdout.strip()) == 64 and not r.stderr for r in results))
        self.assertEqual(len({r.stdout for r in results}), 1)
        self.initialize(exists=True)
        self.assertEqual(len(list(self.directory.glob("secrets.json"))), 1)

    def test_url_encoding_and_failure_diagnostics_do_not_leak(self):
        result = self.initialize(password="private@:/+$ word")
        env = deployment.secret_environment(result)
        self.assertIn("private%40%3A%2F%2B%24%20word", env["NNTDRIVE_DATABASE_URL"])
        # Actual child output, not a fabricated Docker response.
        with self.assertRaises(deployment.BootstrapError) as raised:
            deployment.checked([sys.executable, "-c", 'import os,sys; print(os.environ["POSTGRES_PASSWORD"]); print(os.environ["NNTDRIVE_SECRET_KEY"],file=sys.stderr); sys.exit(1)'], env)
        self.assertNotIn(result["password"], str(raised.exception))
        self.assertNotIn(result["key"], str(raised.exception))


class ComposeConfiguration(unittest.TestCase):
    """Real Compose rendering only: no containers, images, volumes or daemon fixtures."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = {k: v for k, v in os.environ.items() if k not in ("POSTGRES_PASSWORD", "NNTDRIVE_SECRET_KEY", "NNTDRIVE_DATABASE_URL", "NNTDRIVE_DOMAIN")}
        self.base = ["docker", "compose", "--project-directory", str(self.directory), "--project-name", "secrets-unit", "--env-file", "/dev/null"]

    def test_actual_compose_empty_env_bootstrap_render_and_no_leaks(self):
        with patch.dict(os.environ, self.env, clear=True):
            explicit = deployment.resolve_explicit(self.base)
            self.assertEqual(explicit, {"POSTGRES_PASSWORD": "", "NNTDRIVE_SECRET_KEY": ""})
            stored = deployment.initialize(self.directory / "private", "secrets-unit", "", "", lambda: False)
            # Published release file must render with no .env/domain at all.
            config = json.loads(deployment.checked(self.base + ["-f", str(Path(os.environ.get("NNTDRIVE_TEST_RELEASE_COMPOSE", str(ROOT / "deploy/docker-compose.release.yml")))), "config", "--format", "json"], deployment.secret_environment(stored)))
        self.assertEqual(config["services"]["postgres"]["environment"]["POSTGRES_PASSWORD"], stored["password"])
        self.assertEqual(config["services"]["backend"]["environment"]["NNTDRIVE_SECRET_KEY"], stored["key"])
        self.assertEqual(config["services"]["backend"]["environment"]["DATABASE_URL"], deployment.secret_environment(stored)["NNTDRIVE_DATABASE_URL"])

    def test_launcher_real_readonly_docker_ps_with_missing_then_empty_env(self):
        # The real executable path queries Docker and renders the real release
        # file; `ps` cannot create/start/delete any deployment resources.
        for name in ("nntdrive-compose.py", "docker-compose.release.yml"):
            shutil.copyfile(ROOT / "deploy" / name, self.directory / name)
        command = [sys.executable, str(self.directory / "nntdrive-compose.py"), "--project-name", "secrets-test-" + secrets.token_hex(6), "ps"]
        first = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(first.returncode, 0, "launcher failed (diagnostics withheld)")
        path = self.directory / ".nntdrive-secrets/secrets.json"
        before = path.read_bytes()
        stored = json.loads(before)
        (self.directory / ".env").write_text("POSTGRES_PASSWORD=\nNNTDRIVE_SECRET_KEY=\n")
        second = subprocess.run(command, env=self.env, text=True, capture_output=True)
        self.assertEqual(second.returncode, 0, "launcher reuse failed (diagnostics withheld)")
        self.assertEqual(path.read_bytes(), before)
        for output in (first.stdout, first.stderr, second.stdout, second.stderr):
            self.assertNotIn(stored["password"], output)
            self.assertNotIn(stored["key"], output)

    def test_actual_compose_dotenv_and_environment_precedence(self):
        path = self.directory / ".env"
        path.write_text("POSTGRES_PASSWORD='literal$@ word'\nNNTDRIVE_SECRET_KEY=\n")
        base = self.base[:-1] + [str(path)]
        with patch.dict(os.environ, self.env, clear=True):
            self.assertEqual(deployment.resolve_explicit(base)["POSTGRES_PASSWORD"], "literal$@ word")
            os.environ["POSTGRES_PASSWORD"] = "process$$@override"
            self.assertEqual(deployment.resolve_explicit(base)["POSTGRES_PASSWORD"], "process$$@override")


if __name__ == "__main__":
    unittest.main()
