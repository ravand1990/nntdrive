#!/usr/bin/env python3
"""Exercise the CI fail-closed gate with isolated subprocess fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DatabaseGateTests(unittest.TestCase):
    def run_gate(self, *, sql_exit=0, cargo_exit=0, output="test result: ok", configured=True):
        with tempfile.TemporaryDirectory() as directory:
            bin_dir = Path(directory)
            for name, text in {
                "psql": f"#!/bin/sh\nexit {sql_exit}\n",
                "cargo": f"#!/bin/sh\nprintf '%s\\n' '{output}'\nexit {cargo_exit}\n",
            }.items():
                script = bin_dir / name
                script.write_text(text)
                script.chmod(0o755)
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}")
            env.pop("TEST_DATABASE_URL", None)
            if configured:
                env["TEST_DATABASE_URL"] = "postgres://unit-fixture"
            return subprocess.run(["bash", str(ROOT / "scripts/ci-rust-tests.sh")],
                                  env=env, capture_output=True, text=True)

    def test_requires_database_configuration(self):
        self.assertNotEqual(self.run_gate(configured=False).returncode, 0)

    def test_requires_successful_query(self):
        self.assertNotEqual(self.run_gate(sql_exit=1).returncode, 0)

    def test_rejects_successful_cargo_with_skip_notice(self):
        result = self.run_gate(output="skipping PostgreSQL-backed test: fixture outage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing a false green", result.stderr)

    def test_propagates_test_failure(self):
        self.assertNotEqual(self.run_gate(cargo_exit=101).returncode, 0)

    def test_accepts_success(self):
        self.assertEqual(self.run_gate().returncode, 0)


if __name__ == "__main__":
    unittest.main()
