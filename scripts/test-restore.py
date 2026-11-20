#!/usr/bin/env python3
"""Disaster-recovery round trip: back up a real PostgreSQL database, damage it,
restore the dump and prove the original rows come back.

PostgreSQL runs in a disposable Docker container, so this needs the docker CLI
and the pinned postgres image. It never touches the deploy stack, an installed
server or a host database. Missing docker is an error, not a skip: a skipped
restore test would be a false green.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
IMAGE = "postgres:16-alpine"
DB_USER = "nntdrive"
DB_NAME = "nntdrive"

KEEP_ACCOUNT = "11111111-1111-4111-8111-111111111111"
DROP_ACCOUNT = "22222222-2222-4222-8222-222222222222"
DEVICE = "33333333-3333-4333-8333-333333333333"
PROVIDER = "44444444-4444-4444-8444-444444444444"
INTRUDER = "55555555-5555-4555-8555-555555555555"
MARKER = "66666666-6666-4666-8666-666666666666"
ABORT_MARKER = "77777777-7777-4777-8777-777777777777"

SEED_SQL = f"""
INSERT INTO accounts (id, email, password_hash, display_name)
VALUES ('{KEEP_ACCOUNT}', 'keep@example.test', 'hash-keep', 'Keep'),
       ('{DROP_ACCOUNT}', 'drop@example.test', 'hash-drop', 'Drop');
INSERT INTO devices (id, account_id, name, public_key, platform)
VALUES ('{DEVICE}', '{KEEP_ACCOUNT}', 'Device', 'public-key', 'restore-test-platform');
INSERT INTO providers (id, name, host, port, username, password_enc)
VALUES ('{PROVIDER}', 'seed-provider', 'news.example.test', 563, 'seed-user', '\\x00');
"""


def migrations():
    return sorted(path.name for path in (ROOT / "migrations").glob("*.sql"))


def docker(*arguments, stdin=None, timeout=180):
    return subprocess.run(
        ["docker", *arguments], input=stdin, capture_output=True, text=True, timeout=timeout
    )


class RestoreRoundTrip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if docker("--version").returncode != 0:
            raise RuntimeError(
                "the docker CLI is required for the restore round trip; "
                "install docker or run this on the CI runner"
            )
        cls.container = f"nntdrive-restore-test-{os.getpid()}"
        docker("rm", "-f", cls.container)
        started = docker(
            "run", "--rm", "-d", "--name", cls.container,
            "-e", f"POSTGRES_USER={DB_USER}",
            "-e", "POSTGRES_PASSWORD=restore-test",
            "-e", f"POSTGRES_DB={DB_NAME}",
            IMAGE,
        )
        if started.returncode != 0:
            raise RuntimeError(f"cannot start {IMAGE}: {started.stderr.strip()}")
        cls.wait_for_server()

        for name in migrations():
            # A fresh data directory runs a temporary server during initdb that
            # answers one probe and is then shut down, so a migration can still
            # lose its connection right after readiness. Retry that transient
            # window only; a real SQL error fails immediately.
            for attempt in range(4):
                result = docker(
                    "exec", "-i", cls.container,
                    "psql", "-U", DB_USER, "-d", DB_NAME, "-v", "ON_ERROR_STOP=1", "-q",
                    stdin=(ROOT / "migrations" / name).read_text(),
                )
                if result.returncode == 0:
                    break
                transient = ("terminating connection" in result.stderr
                             or "shutting down" in result.stderr
                             or "starting up" in result.stderr)
                if not transient or attempt == 3:
                    raise RuntimeError(f"migration {name} failed: {result.stderr.strip()}")
                time.sleep(2)

    @classmethod
    def wait_for_server(cls):
        """Require two consecutive successful connections a moment apart."""
        successes = 0
        for _ in range(120):
            probe = docker(
                "exec", "-i", cls.container,
                "psql", "-U", DB_USER, "-d", DB_NAME, "-tA", "-c", "SELECT 1",
            )
            successes = successes + 1 if probe.returncode == 0 and probe.stdout.strip() == "1" else 0
            if successes >= 2:
                return
            time.sleep(1)
        raise RuntimeError("PostgreSQL did not stay ready for two consecutive probes")

    @classmethod
    def tearDownClass(cls):
        if getattr(cls, "container", None):
            docker("rm", "-f", cls.container)

    def env(self, **extra):
        env = {
            key: value
            for key, value in os.environ.items()
            if key not in {"USE_LOCAL_PG", "DATABASE_URL", "PG_CONTAINER", "PG_USER", "PG_DB"}
        }
        env["PG_CONTAINER"] = self.container
        env.update(extra)
        return env

    def psql(self, sql):
        result = docker(
            "exec", "-i", self.container,
            "psql", "-U", DB_USER, "-d", DB_NAME, "-tA", "-F", "|", "-v", "ON_ERROR_STOP=1",
            stdin=sql,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return [line for line in result.stdout.splitlines() if line]

    def run_script(self, script, *arguments, confirm=None, env=None):
        return subprocess.run(
            ["bash", str(ROOT / "scripts" / script), *arguments],
            input=confirm, capture_output=True, text=True, timeout=180,
            env=env if env is not None else self.env(),
        )

    def test_guards_reject_unsafe_invocations(self):
        with tempfile.TemporaryDirectory() as directory:
            # No "--yes": refuse before touching a database.
            self.assertEqual(self.run_script("restore.sh", directory).returncode, 2)
            backup = self.run_script("backup.sh", directory)
            self.assertEqual(backup.returncode, 0, backup.stderr)
            # The flag alone is not confirmation; the word must be typed, and an
            # unconfirmed attempt must leave the live database untouched.
            self.psql(
                "INSERT INTO accounts (id, email, password_hash) VALUES "
                f"('{ABORT_MARKER}', 'abort-marker@example.test', 'hash-abort');"
            )
            aborted = self.run_script("restore.sh", directory, "--yes", confirm="no\n")
            self.assertEqual(aborted.returncode, 1)
            self.assertIn("aborted", aborted.stdout + aborted.stderr)
            self.assertEqual(
                self.psql("SELECT count(*) FROM accounts WHERE email = 'abort-marker@example.test';"),
                ["1"],
            )
            self.psql("DELETE FROM accounts WHERE email = 'abort-marker@example.test';")
            # Ambiguous database source fails closed instead of guessing.
            ambiguous_env = self.env(USE_LOCAL_PG="1")
            for script, arguments, confirm in (
                ("backup.sh", [], None),
                ("restore.sh", [directory, "--yes"], "RESTORE\n"),
            ):
                result = self.run_script(script, *arguments, confirm=confirm, env=ambiguous_env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("not both", result.stderr)
        # A backup directory without the dump is rejected, not half-restored.
        with tempfile.TemporaryDirectory() as directory:
            missing = self.run_script("restore.sh", directory, "--yes", confirm="RESTORE\n")
            self.assertEqual(missing.returncode, 1)
            self.assertIn("missing", missing.stderr)

    def test_round_trip_restores_rows_and_verifies_the_dump(self):
        self.psql(SEED_SQL)
        before = self.psql("SELECT email FROM accounts ORDER BY email;")
        self.assertEqual(before, ["drop@example.test", "keep@example.test"])

        with tempfile.TemporaryDirectory() as directory:
            backed_up = self.run_script("backup.sh", directory)
            self.assertEqual(backed_up.returncode, 0, backed_up.stderr)
            backup = Path(directory)
            dump = backup / "nntdrive.dump"
            self.assertTrue(dump.is_file() and dump.stat().st_size > 0)

            digest = hashlib.sha256(dump.read_bytes()).hexdigest()
            checkpoint = json.loads((backup / "checkpoint.json").read_text())
            self.assertEqual(checkpoint["format"], "nntdrive-checkpoint/1")
            self.assertEqual(checkpoint["database_dump"], "nntdrive.dump")
            self.assertEqual(checkpoint["restore_procedure"], "docs/DISASTER_RECOVERY.md")
            self.assertEqual(checkpoint["database_dump_sha256"], digest)
            # The checkpoint must describe the migrations this repository ships.
            self.assertEqual(checkpoint["schema_migrations"], ",".join(migrations()))
            sums = {}
            for line in (backup / "SHA256SUMS").read_text().splitlines():
                checksum, name = line.split()
                sums[name] = checksum
            self.assertEqual(sums["nntdrive.dump"], digest)
            self.assertEqual(sums["checkpoint.json"],
                             hashlib.sha256((backup / "checkpoint.json").read_bytes()).hexdigest())

            # Damage the live database: delete rows and add one that must not survive.
            self.psql(
                "DELETE FROM devices; DELETE FROM providers; "
                f"DELETE FROM accounts WHERE id = '{DROP_ACCOUNT}'; "
                "INSERT INTO accounts (id, email, password_hash) VALUES "
                f"('{INTRUDER}', 'intruder@example.test', 'hash-x');"
            )
            self.assertEqual(self.psql("SELECT email FROM accounts ORDER BY email;"),
                             ["intruder@example.test", "keep@example.test"])

            restored = self.run_script("restore.sh", str(backup), "--yes", confirm="RESTORE\n")
            self.assertEqual(restored.returncode, 0, restored.stderr)
            self.assertIn("restore complete", restored.stdout)
            self.assertEqual(self.psql("SELECT email FROM accounts ORDER BY email;"), before)
            self.assertEqual(self.psql(f"SELECT platform FROM devices WHERE id = '{DEVICE}';"),
                             ["restore-test-platform"])
            self.assertEqual(self.psql(f"SELECT name FROM providers WHERE id = '{PROVIDER}';"),
                             ["seed-provider"])
            self.assertEqual(self.psql(f"SELECT count(*) FROM accounts WHERE id = '{INTRUDER}';"),
                             ["0"])

            # A dump that fails the checksum is rejected before anything is dropped.
            self.psql(
                "INSERT INTO accounts (id, email, password_hash) VALUES "
                f"('{MARKER}', 'marker@example.test', 'hash-m');"
            )
            dump.write_bytes(dump.read_bytes() + b"tampered")
            tampered = self.run_script("restore.sh", str(backup), "--yes", confirm="RESTORE\n")
            self.assertNotEqual(tampered.returncode, 0)
            self.assertEqual(
                self.psql("SELECT email FROM accounts WHERE email = 'marker@example.test';"),
                ["marker@example.test"],
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
