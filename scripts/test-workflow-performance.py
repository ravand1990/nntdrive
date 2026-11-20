#!/usr/bin/env python3
"""Stdlib workflow contracts; actionlint separately validates YAML/expressions."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


def jobs(text):
    return dict(re.findall(r"^  ([\w-]+):\n(.*?)(?=^  [\w-]+:|\Z)",
                           text.split("\njobs:\n", 1)[1], re.M | re.S))


class WorkflowPerformanceTests(unittest.TestCase):
    def setUp(self):
        self.ci = (ROOT / ".github/workflows/ci.yml").read_text()
        self.clients = (ROOT / ".github/workflows/clients.yml").read_text()
        self.release = (ROOT / ".github/workflows/release.yml").read_text()

    def test_independent_checks_start_in_parallel(self):
        for name, body in jobs(self.clients).items():
            if name not in {"android-native-smoke", "windows-app-smoke"}:
                self.assertNotRegex(body, r"(?m)^    needs:", name)
        self.assertNotRegex(jobs(self.ci)["docker"], r"(?m)^    needs:")
        self.assertIn("needs: build-android", jobs(self.clients)["android-native-smoke"])
        self.assertIn("needs: build-windows", jobs(self.clients)["windows-app-smoke"])

    def test_all_required_jobs_and_tests_remain(self):
        self.assertEqual(set(jobs(self.ci)), {"rust", "docker", "wrapper-contracts"})
        self.assertEqual(set(jobs(self.clients)), {
            "analyze", "build-linux", "build-windows", "build-android",
            "android-native-smoke", "windows-app-smoke"})
        for text in (self.ci, self.clients):
            self.assertNotIn("continue-on-error", text)
            self.assertNotIn("paths-ignore:", text)
            self.assertNotRegex(text, r"(?m)^\s+paths:")
            self.assertIn("contents: read", text)
        for command in ("cargo fmt --all -- --check", "cargo clippy --workspace --all-targets -- -D warnings",
                        "bash scripts/ci-rust-tests.sh", "./target/release/nntdrive demo"):
            self.assertIn(command, jobs(self.ci)["rust"])
        self.assertIn("flutter analyze", jobs(self.clients)["analyze"])
        for name in ("analyze", "build-windows"):
            self.assertIn("flutter test --reporter expanded", jobs(self.clients)[name])
            self.assertIn("NNTDRIVE_FFI_PATH", jobs(self.clients)[name])
        self.assertIn("check-android-apk.py", jobs(self.clients)["build-android"])
        smoke = jobs(self.clients)["android-native-smoke"]
        self.assertIn("test -c /dev/kvm", smoke)
        self.assertIn("lib/x86_64/libnntdrive_ffi.so", smoke)
        # The bounded run lives in a repository script because the emulator action
        # executes each `script` line in its own shell.
        self.assertIn("run-android-native-smoke.sh", smoke)
        self.assertIn("integration_test/android_native_test.dart",
                      (ROOT / "scripts/run-android-native-smoke.sh").read_text())
        windows_smoke = jobs(self.clients)["windows-app-smoke"]
        self.assertIn("nntdrive-windows-x64", windows_smoke)
        self.assertIn("integration_test/windows_app_smoke_test.dart", windows_smoke)
        self.assertIn("NNTDRIVE_FFI_PATH", windows_smoke)
        self.assertIn("nntdrive.exe", windows_smoke)

    def test_cache_inputs_and_nonpublishing_scope(self):
        docker = jobs(self.ci)["docker"]
        for contract in ("push: false", "cache-from: type=gha,scope=pr-backend",
                         "cache-to: type=gha,scope=pr-backend,mode=max"):
            self.assertIn(contract, docker)
        for name in ("build-android", "android-native-smoke"):
            body = jobs(self.clients)[name]
            self.assertIn("cache: gradle", body)
            self.assertIn("clients/flutter/android/**/*.gradle.kts", body)
            self.assertIn("clients/flutter/android/gradle/wrapper/gradle-wrapper.properties", body)
        # A pub dependency bump can change Gradle requirements, so the lockfile
        # belongs in the cache key or a stale module cache is reused.
        self.assertIn("clients/flutter/pubspec.lock", jobs(self.clients)["android-native-smoke"])

    def test_android_smoke_builds_outside_the_emulator_and_stays_bounded(self):
        # The emulator job used to resolve Gradle dependencies and compile plugin
        # Kotlin inside the emulator/timer window: a repository failure burned the
        # boot budget and an unbounded Dart VM service wait consumed the rest.
        smoke = jobs(self.clients)["android-native-smoke"]
        self.assertIn("flutter pub get --enforce-lockfile", smoke)
        self.assertIn("flutter build apk --debug --target-platform android-x64", smoke)
        self.assertIn("test -f build/app/outputs/flutter-apk/app-debug.apk", smoke)
        # Shared hosted-runner egress gets 429 from Maven Central; keep Gradle's
        # own artifact retry and the bounded wrapper retry in place.
        self.assertIn("org.gradle.internal.repository.max.tentatives", smoke)
        self.assertIn("for attempt in 1 2 3", smoke)
        # The emulator action runs each `script` line in its own shell, so a
        # multi-line block silently breaks; keep it a single delegated line and
        # hold the bounded run in the repository script instead.
        self.assertIn('script: bash "$GITHUB_WORKSPACE/scripts/run-android-native-smoke.sh"',
                      smoke)
        self.assertNotIn("script: |", smoke)
        runner = (ROOT / "scripts/run-android-native-smoke.sh").read_text()
        self.assertIn("timeout --signal=INT --kill-after=30", runner)
        self.assertIn("timeout_seconds", runner)
        self.assertIn("--no-pub", runner)
        self.assertIn("integration_test/android_native_test.dart", runner)
        self.assertIn("logcat -d -t 3000", runner)
        self.assertIn("android-native-smoke-logcat.txt", smoke)
        self.assertIn("if: failure()", smoke)
        self.assertIn("timeout-minutes: 40", smoke)
        # The assertions themselves must stay: KVM, the real packaged core and the
        # integration test file are unchanged by this reliability work.
        self.assertIn("test -c /dev/kvm", smoke)
        self.assertIn("lib/x86_64/libnntdrive_ffi.so", smoke)
        self.assertNotIn("continue-on-error", smoke)

    def test_release_gates_and_tag_cancellation_are_preserved(self):
        release = jobs(self.release)
        for name in ("image", "clients"):
            self.assertIn("needs: test", release[name])
        self.assertIn("needs: [image, clients]", release["github-release"])
        self.assertIn("provenance: true", release["image"])
        self.assertIn("sbom: true", release["image"])
        self.assertNotIn("scope=pr-backend", self.release)
        self.assertIn("sha256sum * > SHA256SUMS.txt", release["github-release"])
        for text in (self.clients, self.ci):
            self.assertIn("cancel-in-progress: ${{ !startsWith(github.ref, 'refs/tags/') }}", text)
        self.assertIn("cancel-in-progress: false", self.release)
        self.assertIn("bash scripts/ci-rust-tests.sh", release["test"])


if __name__ == "__main__":
    unittest.main()
