# Development

## Container-only checks (no host SDK installation)

Use `bash scripts/dev-check.sh build` once, then `bash scripts/dev-check.sh all`.
See [container development](CONTAINER-DEVELOPMENT.md) for versions, per-worktree
caches, bounded disposable containers, and isolated test PostgreSQL. This does
not start or change the deployment/evaluation stack.

## Prerequisites

- Rust stable (1.82+; CI uses current stable)
- PostgreSQL 14+ for storage/backend integration tests
- Optional: Docker for the deployment stack
- Optional: Flutter 3.47.9 for the clients

On Windows, run the Rust build/tests inside WSL2 (Linux) — the backend targets
Linux and the test suite uses real TCP/PostgreSQL.

## Database for tests

```sql
CREATE DATABASE nntdrive_test;
-- or use any database/user with CREATE SCHEMA permission
```

```bash
export TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/nntdrive_test
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/nntdrive_test
```

Each test creates an isolated PostgreSQL schema, runs all migrations, and drops
it afterwards. Tests can skip (with a printed notice) if no database is reachable locally.
CI requires a successful SQL query and rejects every PostgreSQL skip notice;
merely setting `TEST_DATABASE_URL` is not sufficient. See [CI coverage](CI.md)
for exact supported-platform checks, required-check recommendations and gaps.

## Commands

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets
cargo test --workspace --all-targets
cargo run -p nntdrive-cli -- demo --keyfile-out /tmp/demo.keyfile.json
cargo build --release -p nntdrive-backend -p nntdrive-cli
```

Targeted:

```bash
cargo test -p nntdrive-crypto
cargo test -p nntdrive-nntp
cargo test -p nntdrive-storage
cargo test -p nntdrive-sync
cargo test -p nntdrive-backend
```

## Client SDK setup (verified versions)

Linux/WSL (used for the verified Linux and Android builds):

```bash
# Rust backend + tests
rustup toolchain install stable

# Flutter 3.47.9 / Dart 3.13.7
curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.47.9-stable.tar.xz \
  | tar -xJ -C "$HOME"          # or /opt/flutter
export PATH="$HOME/flutter/bin:$PATH"

# Java 17 + Linux desktop toolchain
sudo apt-get install -y openjdk-17-jdk-headless clang cmake ninja-build \
  pkg-config libgtk-3-dev liblzma-dev

# Android command-line tools + SDK 36
sudo mkdir -p /opt/android-sdk/cmdline-tools
curl -fsSL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip \
  -o /tmp/cmdline-tools.zip
sudo unzip -q /tmp/cmdline-tools.zip -d /opt/android-sdk/cmdline-tools/latest
# flatten the archive's cmdline-tools/ directory, then:
export ANDROID_SDK_ROOT=/opt/android-sdk
yes | sdkmanager --sdk_root="$ANDROID_SDK_ROOT" --licenses
sdkmanager --sdk_root="$ANDROID_SDK_ROOT" platform-tools 'platforms;android-36' 'build-tools;36.0.0'
flutter config --android-sdk "$ANDROID_SDK_ROOT"

# Build and test
cd clients/flutter
flutter pub get
flutter analyze
NNTDRIVE_FFI_PATH="$PWD/linux/lib/libnntdrive_ffi.so" flutter test
flutter build linux --release
flutter build apk --release
```

Use `bash scripts/build-clients.sh` for the complete path (builds the Rust FFI,
copies it, runs tests, builds both artifacts). Flutter/Gradle also auto-installed
Android NDK 28c and platform 35 during the first APK build. The APK is a release
build signed with the debug key; configure a real keystore before distributing.

Windows (for `flutter build windows`):

- Flutter 3.47.9 for Windows, Visual Studio 2022 Build Tools with
  `Microsoft.VisualStudio.Component.VC.Tools.x86.x64` and a Windows 10/11 SDK.
- Enable **Developer Mode** (Settings → For developers) so Flutter can create
  plugin symlinks. Without it the build stops with
  `Building with plugins requires symlink support`.
- Build the Rust DLL and copy it next to the runner:
  `cargo build --release -p nntdrive-ffi` then
  `copy target\release\nntdrive_ffi.dll clients\flutter\windows\runner\`.
- Then `flutter pub get && flutter build windows --release` in `clients/flutter`.

iOS requires macOS + Xcode (`flutter build ios --no-codesign`). It cannot be
built from Windows or Linux.

## Code map

- `crates/crypto/src/lib.rs` — key hierarchy, keyfile, auth verifier.
- `crates/crypto/src/envelope.rs` — the versioned XChaCha20-Poly1305 envelope.
- `crates/crypto/src/device.rs` — X25519 wrapping, keyring, enrollment.
- `crates/crypto/src/recovery.rs` — recovery kit.
- `crates/nntp/src/client.rs` — connection/pool/retry logic.
- `crates/nntp/src/yenc.rs`, `nzb.rs`, `article.rs` — wire formats.
- `crates/nntp/src/mock.rs` — in-process server with delete/corrupt/outage/expiry.
- `crates/storage/src/chunker.rs` — bounded-memory FastCDC stream.
- `crates/storage/src/erasure.rs` — stripes, reconstruction, hashes.
- `crates/storage/src/engine.rs` — client upload/download and server jobs.
- `crates/storage/src/store.rs` — SQL and the test-database helper.
- `crates/sync/src/scanner.rs`, `reconcile.rs`, `engine.rs`, `journal.rs`.
- `crates/backend/src/{auth,api,admin,jobs,state}.rs`, `static/admin.html`.
- `migrations/` — ordered SQL, applied by `sqlx::migrate!` at startup.

## Testing philosophy

The two-device Dart FFI smoke can run without a deployment or provider account.
In the existing Flutter check container (with the isolated test database ready,
`TEST_DATABASE_URL` and `NNTDRIVE_FFI_PATH` configured), run from repository root:

```bash
cargo run --offline --locked -p nntdrive-client --example sync_ffi_smoke
```

The fixture fails closed without PostgreSQL, starts an in-process mock NNTP and
real HTTP API on loopback, runs `tool/sync_smoke.dart`, then drops its test schema.
It checks incremental byte events across Dart/Rust, two-device edit propagation,
all three conflict choices and recovery of both versions. It is a separate smoke
command, not implicitly run by `cargo test` or the default check wrapper.

- The NNTP mock is a real TCP server; client tests use the real protocol,
  yEnc, pooling and retry code. No real provider is ever contacted.
- Storage tests use real PostgreSQL and the mock provider. They cover upload,
  download, dedupe, shard loss, corruption, repair, refresh, wrong keys and
  provider outage.
- Backend tests use the real router (`tower::oneshot`) and a real database.
  They cover registration/login, token revocation, tenant isolation, ciphertext
  upload, article proxying, admin authorization, user edits and provider
  create/edit/delete.
- Sync tests use two temp directories and a shared in-memory remote to simulate
  two devices, offline edits, conflicts, renames, deletions and selective-sync
  exclusions.
- Destructive tests are simulated client-side (`MockStore::delete_message`,
  `corrupt_message`, `expire_older_than`, `set_outage`), never against a provider.

## Conventions

- Keep encryption, synchronization and NNTP transport separate.
- Never add a code path that sends plaintext or keys to the backend.
- Every metadata mutation is scoped by `account_id` and tested for isolation.
- Prefer established crates; do not hand-roll cryptography.
- New SQL goes in a numbered migration; queries use runtime `sqlx::query`.
- Document OS limitations rather than faking platform behavior.

## Current gaps

See `STATUS.md`. The largest remaining work is the Flutter↔Rust bridge, platform
integrations (FUSE/WinFsp/FileProvider/DocumentsProvider), sharing/link UI,
AMK epoch rotation automation, and a security review.
