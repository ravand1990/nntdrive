# Development

## Prerequisites

- Rust stable (1.82+; CI uses current stable)
- PostgreSQL 14+ for storage/backend integration tests
- Optional: Docker for the deployment stack
- Optional: Flutter 3.x for the client scaffold

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
it afterwards. Tests skip (with a printed notice) if no database is reachable;
CI sets `TEST_DATABASE_URL` and therefore always runs them.

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

- The NNTP mock is a real TCP server; client tests use the real protocol,
  yEnc, pooling and retry code. No real provider is ever contacted.
- Storage tests use real PostgreSQL and the mock provider. They cover upload,
  download, dedupe, shard loss, corruption, repair, refresh, wrong keys and
  provider outage.
- Backend tests use the real router (`tower::oneshot`) and a real database.
  They cover registration/login, token revocation, tenant isolation, ciphertext
  upload, article proxying and admin authorization.
- Sync tests use two temp directories and a shared in-memory remote to simulate
  two devices, offline edits, conflicts, renames, deletions.
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
