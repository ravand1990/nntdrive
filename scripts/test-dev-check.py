#!/usr/bin/env python3
"""Fast wrapper/Compose contracts; no SDK images or running containers needed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import fcntl

ROOT = Path(__file__).resolve().parents[1]


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for name in ("scripts/dev-check.sh", "deploy/docker-compose.checks.yml"):
            target = self.root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        # Isolate wrapper orchestration from Docker cleanup in unit tests.
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOCKER_CALLS"\n')
        docker.chmod(0o755)
        self.calls = self.root / "calls"
        self.env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}",
                        DOCKER_CALLS=str(self.calls))

    def run_wrapper(self, action, *args):
        return subprocess.run(["bash", str(self.root / "scripts/dev-check.sh"), action, *args],
                              env=self.env, capture_output=True, text=True)

    def test_config_is_scoped_and_cleans_up(self):
        result = self.run_wrapper("config")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        for call in calls:
            self.assertIn("--env-file /dev/null --project-name nntdrive-check-", call)
            self.assertIn(str(self.root / "deploy/docker-compose.checks.yml"), call)
        self.assertTrue(calls[0].endswith(" config"))
        self.assertTrue(calls[1].endswith(" down --timeout 10"))

    def test_custom_flutter_command_uses_isolated_service_and_cleanup(self):
        result = self.run_wrapper("flutter-exec", "dart", "format", "lib/desktop_host.dart")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(len(calls), 2)
        self.assertIn("run --rm --no-deps -T flutter dart format lib/desktop_host.dart", calls[0])
        self.assertTrue(calls[1].endswith(" down --timeout 10"))

    def test_overlap_never_calls_docker(self):
        state = self.root / ".toolchain"
        state.mkdir()
        with (state / "check.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_wrapper("all")
        self.assertEqual(result.returncode, 75)
        self.assertFalse(self.calls.exists())

    def test_unknown_action_fails(self):
        self.assertEqual(self.run_wrapper("unknown").returncode, 2)

    def test_real_compose_isolated_configuration(self):
        env = dict(os.environ, CHECKOUT=str(self.root),
                   CHECK_STATE=str(self.root / ".toolchain"),
                   LOCAL_UID=str(os.getuid()), LOCAL_GID=str(os.getgid()))
        result = subprocess.run(["docker", "compose", "--env-file", "/dev/null", "-f",
                                 str(self.root / "deploy/docker-compose.checks.yml"),
                                 "config", "--format", "json"], env=env,
                                check=True, capture_output=True, text=True)
        config = json.loads(result.stdout)
        services = config["services"]
        self.assertTrue(config["networks"]["checks"]["internal"])
        self.assertNotIn("ports", services["test-db"])
        self.assertIn("@sha256:", services["test-db"]["image"])
        for name in ("rust", "flutter"):
            self.assertEqual(set(services[name]["networks"]), {"checks"})
            self.assertEqual(services[name]["user"], f"{os.getuid()}:{os.getgid()}")
            self.assertEqual(services[name]["environment"]["HOME"], "/state/home")
        for name in ("rust-fetch", "flutter-fetch"):
            self.assertEqual(set(services[name]["networks"]), {"default"})


if __name__ == "__main__":
    unittest.main()
