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
| `CI / wrapper-contracts` | Four Python wrapper/real Compose configuration tests; five subprocess tests for the fail-closed database gate. No SDK image build. |
| `CI / rust` | fmt, Clippy, full workspace tests against disposable PostgreSQL 16 and mock NNTP, release backend/CLI build, storage demo. `psql` must succeed and any PostgreSQL skip notice fails the job. Test output uses `--nocapture`; pipeline failures propagate. |
| `CI / docker` | Container build only, no push/deploy. |
| `Clients / analyze` | Linux release Rust FFI build, Flutter analysis and full unit/native bridge suite with explicit native library path. Missing native path/file now fails rather than returning a false pass. |
| `Clients / build-linux` | Native library plus Flutter release bundle and artifact. Not a GUI launch or installed-app update test. |
| `Clients / build-windows` | Native MSVC DLL, full Flutter unit/native bridge suite on Windows, release build, bundled DLL existence check, ZIP artifact. Failures are no longer allowed. Not installer, process restart, clean-machine or signed-distribution verification. |
| `Clients / build-android` | Rust libraries for arm64-v8a, armeabi-v7a and x86_64, release APK; inspect all three packaged libraries for ELF headers before artifact upload. Debug signing remains. This is packaging coverage, NOT emulator/device runtime or E2E. |
| `Clients / android-native-smoke` | KVM-required Ubuntu emulator (API 35, x86_64), reusing the release APK's actual Rust library: account/keyfile unlock, encrypted filename round-trip, wrong-password rejection, real path_provider platform channel and app-private file round-trip. Not backend sync, installed release APK launch, or full E2E. 25-minute job/5-minute boot limit, 2 cores/2 GiB emulator RAM. |
| `Clients / build-ios` | Informational/non-blocking unsigned compile attempt; iOS implementation/FFI/signing is incomplete (#12). Do not require it or claim iOS support. |

macOS client delivery is not covered. Windows/Linux updater replacement and
restart remain #28; installer/signing/clean-machine validation remains #11.
Android add-folder/sync integration remains #17. The new integration_test smoke
runs assertions inside an Android app process rather than relabeling a build
E2E; it does not provision a backend or claim sync/background/provider coverage.
KVM is required explicitly: absence fails instead of silently using an unusably
slow software emulator. Successful runtime coverage must be confirmed by the
`android-native-smoke` result for the exact commit.

## Manual pinned container drift check

Dispatch **Container checks (manual)** explicitly against the desired ref. It
builds the repository-owned pinned Rust/Flutter images, then runs
`bash scripts/dev-check.sh all` with real isolated PostgreSQL and native FFI.
No schedule or automatic SDK rebuild is added. Budget: one Ubuntu runner,
60-minute timeout, at least 20 GiB initial free disk; Compose limits Rust/Flutter
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
Manual container checks and informational iOS are not required checks.

External actions changed in CI/Clients and the new manual workflow are pinned
to exact commit SHAs resolved using GitHub's commit API. Other existing release
action references remain unchanged; Rust stable and cargo-ndk are still rolling
inputs, so this is not fully reproducible or supply-chain-complete CI.
