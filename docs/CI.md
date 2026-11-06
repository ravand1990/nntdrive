# CI verification and limits

GitHub Actions is the primary repeatable verification path; no persistent test
VMs or production services are needed. A workflow definition is not evidence of
a successful run. Inspect the run for the exact commit before claiming coverage.

## Automatic checks

Both CI and Clients run on every main push and PR (no path-filter gaps). Token
permissions are read-only. Superseded branch runs cancel; tag/release client runs
do not. Jobs have timeouts; Windows/Linux/Android build jobs are blocking in the
workflow, not proof of repository branch protection.

| Job | Contract |
|---|---|
| `CI / wrapper-contracts` | Four Python wrapper/real Compose configuration tests; five subprocess tests for the fail-closed database gate; four workflow performance/coverage contracts; agent policy contracts and actionlint. No SDK image build. |
| `CI / rust` | fmt, Clippy, full workspace tests against disposable PostgreSQL 16 and mock NNTP, release backend/CLI build, storage demo. `psql` must succeed and any PostgreSQL skip notice fails the job. Test output uses `--nocapture`; pipeline failures propagate. |
| `CI / docker` | Container build only, no push/deploy. |
| `Clients / analyze` | Linux release Rust FFI build, Flutter analysis and full unit/native bridge suite with explicit native library path. Missing native path/file now fails rather than returning a false pass. |
| `Clients / build-linux` | Native library plus Flutter release bundle and artifact. Not a GUI launch or installed-app update test. |
| `Clients / build-windows` | Native MSVC DLL, full Flutter unit/native bridge suite on Windows, release build, bundled DLL existence check, ZIP artifact. Failures are no longer allowed. Not installer, process restart, clean-machine or signed-distribution verification. |
| `Clients / build-android` | Rust libraries for arm64-v8a, armeabi-v7a and x86_64, release APK; inspect all three packaged libraries for ELF headers before artifact upload. Debug signing remains. This is packaging coverage, NOT emulator/device runtime or E2E. |
| `Clients / android-native-smoke` | KVM-required Ubuntu emulator (API 35, x86_64), reusing the release APK's actual Rust library: account/keyfile unlock, encrypted filename round-trip, wrong-password rejection, real path_provider platform channel and app-private file round-trip. Not backend sync, installed release APK launch, or full E2E. 25-minute job/5-minute boot limit, 2 cores/2 GiB RAM/2 GiB userdata. It reclaims only unused .NET on the disposable hosted runner; first boot failed because default userdata requested 7.4 GiB with only 6.1 GiB free, not because KVM was absent. |

macOS client delivery is not covered. Windows/Linux updater replacement and
restart remain #28; installer/signing/clean-machine validation remains #11.
Android add-folder/sync integration remains #17. The new integration_test smoke
runs assertions inside an Android app process rather than relabeling a build
E2E; it does not provision a backend or claim sync/background/provider coverage.
KVM is required explicitly: absence fails instead of silently using an unusably
slow software emulator. Successful runtime coverage must be confirmed by the
`android-native-smoke` result for the exact commit.

## Performance evidence — issue #46

### Execution graph and cache boundaries

`rust`, `wrapper-contracts` and the **non-publishing** Docker build now start
independently. Linux, Windows and Android client builds no longer wait for
Linux analysis. Analysis and both Linux/Windows native unit suites still run;
all eight CI/Clients jobs remain required for acceptance. This trades a little
extra work on failing commits for a shorter successful critical path. No path
filters, optional tests, artifact substitutions or release bypasses were added.
The Android smoke still waits for the actual release APK and extracts its
x86_64 core before exercising KVM runtime assertions.

Both Android jobs use setup-java's Gradle dependency/wrapper cache, keyed on
all Android Gradle Kotlin scripts and wrapper properties. Flutter still resolves
pub dependencies and Gradle still executes the builds/tests; a cache hit never
skips verification. GitHub's ref-scoped cache isolation prevents PR writes from
being restored on main/tag release runs. PR caches contain no credentials.
The build-only Docker cache uses `scope=pr-backend`, separate from the unchanged
release image cache; no PR-built image/artifact is promoted to a release.
Release `image` and reusable `clients` still depend on `test`; `github-release`
still waits for both. SBOM, provenance, checksums and tag cancellation policy
are unchanged. Release workflow itself is intentionally unchanged.

### Actual baseline (queried 2026-11-06)

REST Actions run timestamps (`created_at` through completed `updated_at`, in
seconds, including queue/finalization) give the following three most recent
successful **paired PR** runs before this change. Failed/cancelled/in-flight
runs and main pushes are excluded, not counted as fast successes. These are
warm-cache historical samples, not a controlled identical-source benchmark.

| PR head | CI run / seconds | Clients run / seconds | Paired wall-clock seconds |
|---|---|---|---|
| `cc0fea35` | [42136628013](https://github.com/ravand1990/nntdrive/actions/runs/42136628013) / 361 | [42136628033](https://github.com/ravand1990/nntdrive/actions/runs/42136628033) / 924 | 924 |
| `58f29ff6` | [42135429299](https://github.com/ravand1990/nntdrive/actions/runs/42135429299) / 465 | [42135428996](https://github.com/ravand1990/nntdrive/actions/runs/42135428996) / 1022 | 1022 |
| `a2b1114f` | [42134621216](https://github.com/ravand1990/nntdrive/actions/runs/42134621216) / 447 | [42134621207](https://github.com/ravand1990/nntdrive/actions/runs/42134621207) / 914 | 914 |

Median CI: **447 s (7m27s)**; Clients and paired PR median: **924 s (15m24s)**.
The second pair's workflows were created one second apart; paired duration is
from earliest creation to latest completion. Numbers were computed with Python
`datetime` and `statistics.median`, not estimated from job definitions.

For `cc0fea35`, actual jobs (`started_at` to `completed_at`) were:
CI rust 184 s, wrapper-contracts 6 s, Docker 170 s; Clients analyze 73 s,
Linux 98 s, Windows 282 s, Android 382 s, Android smoke 461 s.
The Docker build step alone took 150 s, after waiting for Rust.
Android APK compilation took 273 s; emulator action (boot, debug build, tests)
took 414 s. Thus Android build plus runtime remains the primary slow path;
Gradle caching targets repeated dependency/build setup, not reduced assertions.

Historical release [41944403569](https://github.com/ravand1990/nntdrive/actions/runs/41944403569)
(`v0.4.1`, `eb6beca0`) took **1357 s (22m37s)**. Its actual jobs were test 566 s,
image 456 s, analyze 111 s, Linux 173 s, Windows 241 s, Android 656 s,
github-release 12 s, and the then-optional failed iOS job 65 s.
That older graph predates the now-required Android smoke and Windows tests,
so it is a historical bottleneck reference, **not** a coverage-equivalent
post-change release comparator. No release/tag/dispatch was triggered.

### Post-change evidence and acceptance gate

Measured on 2026-11-06 at exact implementation head
`5dde6409540d3396c1f481f159311eb71a57270d`, using CI run
[42143717954](https://github.com/ravand1990/nntdrive/actions/runs/42143717954)
and Clients run
[42143717945](https://github.com/ravand1990/nntdrive/actions/runs/42143717945).
Attempts 2–4 were deliberate **full CI/Clients reruns**, not releases or
failed-job-only reruns. Every successful sample has all eight successful jobs.

| Attempt | Cache state | CI seconds | Clients seconds | Paired seconds |
|---|---|---:|---:|---:|
| 1 | New Gradle/Docker caches cold; existing Rust/Flutter warm | 374 | 734 | 734 |
| 2 | Warm | 211 | 593 | 594 |
| 4 | Warm | 207 | 596 | 597 |

Paired median: **597 s (9m57s), 35.4% below the 924 s baseline**.
CI median: **211 s**, versus 447 s; Clients median: **596 s**, versus 924 s.
Warm paired samples were 594/597 s. This is a small hosted-run sample with
historical different-source baselines, not a controlled runner benchmark.
The initial run is not a wholly cold SDK benchmark: its pre-existing Rust,
Flutter and pub caches hit. The initial Docker cache build step took 354 s;
warm Docker jobs took 20/16 s with logged BuildKit `CACHED` layers. Initial
Android setup logged `gradle cache is not found`, then saved the cache;
the downstream smoke and warm reruns restored
`setup-java-Linux-x64-gradle-aad7385e710f724488d56a391f05e5d776f01be5a0eaebcac35ff9db5bfdaa4b`.
Android APK build steps took 265 s initially and 145 s in attempt 2,
versus the historical 273 s. Smoke emulator/build/test action took 270/223 s,
versus historical 414 s. Builds and assertions still actually ran.

| Successful job duration (seconds) | Initial | Warm attempt 2 | Warm attempt 4 |
|---|---:|---:|---:|
| docker | 372 | 20 | 16 |
| rust | 179 | 189 | 202 |
| wrapper-contracts | 11 | 9 | 23 |
| analyze | 91 | 77 | 97 |
| build-linux | 123 | 107 | 103 |
| build-windows | 316 | 275 | 289 |
| build-android | 414 | 286 | 298 |
| android-native-smoke | 315 | 300 | 289 |

Attempt 3 is **excluded as failed**, not counted as a fast success: CI passed
in 132 s, Clients failed in 605 s. All builds/analyze passed, but Android
smoke failed before assertions with `Failed to start Dart Development Service`
after installing its debug APK. No failure was made optional or masked.
Attempt 4 reran both complete workflows successfully without source changes.
This observed runtime-start flake remains a limitation, not a proven fix.

Durations use each attempt's `run_started_at` through completed `updated_at`,
including runner wait and finalization; paired time is earliest start through
latest completion. Initial `created_at` equals `run_started_at`. A rerun's
original run creation would incorrectly include the deliberate idle interval,
so attempt-local starts are used instead. Attempt 2 CI jobs started 21/151 s
after its request; that runner wait is included. Attempt 1 metadata's terminal
Clients `updated_at` is 01:37:28Z (one second later than the first run-list
read). All values are calculated from saved REST JSON with Python.

The latest measured successful attempt 4 produced client artifacts:
`nntdrive-linux-x64` **13471056147**, `nntdrive-windows-x64` **13470903483**,
`nntdrive-android` **13470584487**. Earlier attempts' artifacts are not
substituted for this attempt. Documentation-only commits after the measured
implementation head require their own exact-head eight-job/artifact readback
before merging; these measurements do not establish a future head's green state.
Release workflow is unchanged, and no release/tag/dispatch was triggered.

Local checks need no SDK installation: `python3 scripts/test-workflow-performance.py`,
existing Python contracts, Bash syntax checks and the pinned actionlint container.
The new contracts were also run against baseline workflows: parallelism/cache
tests failed as intended, while coverage/release invariants passed.

## Declarative environment launcher

See [test environments](TEST-ENVIRONMENTS.md) for the six-target matrix and
`bash scripts/test-env.sh TARGET`: local isolated checks, exact-head correlated
manual Clients dispatch/wait and explicit Windows runtime provisioning refusal.
Hosted builds are not installed-app/E2E evidence. This first increment preserves
all existing eight acceptance jobs and adds a manual workflow plus launcher
contracts. For `linux-client`, a required follow-on job downloads the actual
release bundle and performs a network-isolated Xvfb live-process/visible-window
smoke with always-uploaded logs, screenshot and version-provenance report.
The helper's mocked subprocess contracts run in wrapper-contracts; they are not
live GUI evidence. Exact-head hosted runtime execution remains unverified until
this manual workflow is registered and explicitly dispatched. No release,
deployment or privileged self-hosted execution is enabled.

## Manual pinned container drift check

Dispatch **Container checks (manual)** explicitly against the desired ref. It
builds the repository-owned pinned Rust/Flutter images, then runs
`bash scripts/dev-check.sh all` with real isolated PostgreSQL and native FFI.
No schedule or automatic SDK rebuild is added. Budget: one Ubuntu runner,
60-minute timeout, at least 20 GiB initial free disk after removing unused host
Android/.NET SDKs **only on the disposable GitHub-hosted Linux runner** (the first
run exposed just 14 GiB free and correctly failed its headroom gate); Compose limits Rust/Flutter
to 2 CPUs/6 GiB/512 PIDs, DB to 1 CPU/768 MiB/128 PIDs with 512 MiB tmpfs.
Per-checkout caches last only for the runner lifetime; no credentials, production
volumes or Docker socket are mounted inside toolchains. The wrapper owns its
worktree-specific lock/network/cleanup. Failure is visible, not an optional green.

## Release safety and required checks

Release runs only on `v*` tag pushes or explicit dispatch; main pushes do not
publish images, releases or deployments. Its Rust test job uses the same
fail-closed DB gate; its reusable Clients workflow inherits blocking Windows.
No release is intentionally triggered by this change.

Recommended required checks: `wrapper-contracts`, `rust`, `docker`, `analyze`,
`build-linux`, `build-windows`, `build-android`; add `android-native-smoke` after
confirming the first hosted KVM run. Confirm exact check names in the
repository UI before configuring. Branch-protection inspection returned HTTP
403 with the current token: enforcement is **not verified or configured here**.
Manual container checks are not required checks. iOS builds are not currently
part of the workflow; this does not imply iOS support.

External actions changed in CI/Clients and the new manual workflow are pinned
to exact commit SHAs resolved using GitHub's commit API. Other existing release
action references remain unchanged; Rust stable and cargo-ndk are still rolling
inputs, so this is not fully reproducible or supply-chain-complete CI.
