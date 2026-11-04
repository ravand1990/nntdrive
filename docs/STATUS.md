# Project status

Last updated: 2026-11-04. This file is the handoff record for the next agent.

## Verified working

Everything below is exercised by `cargo test --workspace --all-targets` (79 tests)
against real PostgreSQL and an in-process NNTP server, plus the CLI demo.

| Area | Evidence |
|---|---|
| Crypto round-trips, tamper detection, wrong key rejection, nonce randomness, key separation, recovery kit, device enrollment, epoch rotation | `nntdrive-crypto` tests |
| yEnc, NZB, Message-IDs, dot-stuffing, auth, pooling, retries, concurrency bounds, provider fallback | `nntdrive-nntp` tests |
| Chunk bounds/determinism/empty files, RS reconstruction, manifest validation | `nntdrive-storage` unit tests |
| Encrypted upload/download, plaintext never on the wire, dedupe, shard loss, total loss, repair, refresh, wrong key, provider outage, version history | `nntdrive-storage/tests/storage.rs` |
| Scanner ignore rules, case collisions, path validation, rename detection, concurrent offline edits, conflict preservation, delete propagation | `nntdrive-sync` tests |
| Register/login/logout, revoked device, admin authorization, tenant isolation, ciphertext upload, article proxy, dedupe lookup, shard locations | `nntdrive-backend/tests/api.rs` |
| Real client SDK: register → create node → encrypted upload → manifest → download → decrypt → verify; dedupe; unauthorized access | `crates/client/tests/e2e.rs` |
| Dart ↔ Rust FFI: account generation, keyfile unlock, name seal/open with wrong-key rejection | `clients/flutter/test/native_test.dart` + `crates/ffi` tests |
| Live deployment: dev Compose stack with mock NNTP; register/upload/download through the API | `crates/client/examples/smoke.rs` (verified) |
| Docker image build, Compose stack, healthcheck, admin page, CLI bootstrap, admin API | ✅ verified locally (image built, stack started, `/healthz` 200, admin stats returned) |
| Flutter client analyze/tests, Linux/Android/Windows release builds | ✅ clean analyze, Dart FFI test passes; Linux and Windows bundles run, Android APK (63 MB, debug-signed) embeds all ABIs |

Run it yourself:

```bash
export TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/nntdrive_test
cargo test --workspace --all-targets

# full local app stack (mock Usenet provider)
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.dev.yml up -d --build
bash scripts/build-clients.sh
cargo run -p nntdrive-client --example smoke -- http://127.0.0.1:18080 /tmp/anyfile
```

Demo output (2 MB input, 40 % redundancy in the demo config):

```
upload: chunks_new=1 articles=2 bytes_posted=239668
download + decrypt + verify: OK (2000000 bytes, 1 shards)
health: recoverable=true degraded=false shards=2/2
simulated loss of 1 articles (one per stripe)
health after loss: recoverable=true degraded=true shards=1/2
download despite loss: OK (erasure coding reconstructed missing shards)
repair: stripes_repaired=1 shards_reposted=1 unrecoverable=0
health after repair: recoverable=true degraded=false shards=2/2
re-upload identical content: chunks_reused=1 new_articles=0
whole-stripe loss correctly reported: data is unrecoverable: ...
```

## Phase status

| Phase | State |
|---|---|
| 1. Working storage engine | **Done and tested** (CLI demo uploads, downloads, decrypts, verifies) |
| 2. Self-healing storage | **Done and tested** (health, repair, refresh, snapshots via sealed manifests, simulated loss) |
| 3. Desktop synchronization | **Client implemented for manual upload/download/versioning on Linux, Android and Windows; automatic folder sync engine tested but not yet driven by the UI** |
| 4. Virtual filesystem | **Not implemented** (WinFsp/FUSE design only) |
| 5. Mobile clients | **Android app builds and performs encrypted upload/download; iOS unbuilt; no DocumentsProvider/File Provider/photo backup** |
| 6. Sharing & production readiness | **Partial**: backend, admin dashboard, auth, jobs, Docker, backups, CI done; sharing/link endpoints absent; hardening/audit pending |

## What is intentionally not claimed

- Usenet retention is not guaranteed; the system reports unrecoverable data.
- Posted articles cannot be reliably physically deleted. Deleting a file only
  removes the logical index/tombstones the manifest; copies remain on Usenet and
  may be retrievable by someone who recorded Message-IDs.
- The backend is not trusted with plaintext; do not add a server-side decrypt
  path.
- No security audit. No production durability claim.
- The client stores the password-wrapped keyfile and an (unused) device identity
  secret in shared preferences; move the device secret to the platform keystore
  before relying on device enrollment. The keyfile itself is Argon2id-wrapped.
- Automatic folder synchronization is not wired to the UI yet; upload/download
  are manual.

## Immediate next tasks (in order)

1. **Sync engine integration**: implement the `Remote` adapter over the HTTP API
   and add a "Choose folder / Sync now / Pause" UI with conflict review.
   `crates/sync` already reconciles and preserves conflicts.
2. **Windows build**: enable Developer Mode on the build host, build
   `nntdrive_ffi.dll`, bundle it, and produce `nntdrive.exe`. Code is ready;
   only the host policy blocks it here.
3. **iOS**: build the Rust static library as an XCFramework, add the File
   Provider extension and BGTaskScheduler integration; requires macOS.
4. **AMK epoch rotation** on device revocation (client command + keyring update);
   currently the backend only tells the client rotation is required.
5. **Sharing**: complete folder share endpoints and per-share wrapped keys, link
   tokens with password/expiry; share the AMK-derived folder key without exposing
   the AMK.
6. **Virtual drives**: FUSE (Linux) and WinFsp (Windows) adapters with range
   reads, write-back cache, offline pinning and safe interrupted writes.
7. **Mobile integrations**: Android DocumentsProvider + WorkManager/JobScheduler;
   iOS File Provider extension + BGTaskScheduler with honest background limits.
8. **Security review**, fuzzing of article/yEnc parsers, rate limiting at the
   proxy, password reset policy, audit logging coverage.
9. **Tests to add**: interrupted upload/download, huge-file memory ceiling
   measurement, replayed manifest, provider backbone correlation,
   restore-from-dump automation, Flutter integration tests for the upload flow.

## Known bugs / rough edges

- SSE only supports `Authorization` headers (fine for Dart/Flutter HTTP clients,
  not for browser `EventSource`).
- Admin provider changes require a backend restart (deliberate; documented in UI).
- `nntdrive_storage::store::platform_totals` casts aggregate sums to `bigint` because
  PostgreSQL returns `numeric`; keep casts when editing.
- Full-text search is impossible server-side (names/content encrypted); the
  client must cache a decrypted index.
- Cleanup of orphaned chunks (upload aborted before commit) is not implemented.
  Add a job that deletes chunks unreferenced by any manifest after a grace period.
- No AMK rotation command yet; device revocation instructs the client but does
  not perform client-side key rotation automatically.
- The Docker image was verified with the legacy Docker builder in WSL; BuildKit
  is used in CI. No multi-arch image is published.
- Client CI builds Linux/Android; Windows/iOS jobs stay non-blocking until a
  Developer-Mode/ macOS build is verified in CI.
- The app's "upload" of a new file creates the node first; if the upload fails it
  tombstones the node. An interrupted version upload leaves the previous version
  intact (the manifest commits last).
