# Project status

Last updated: 2026-11-04. This file is the handoff record for the next agent.

## Verified working

Everything below is exercised by `cargo test --workspace --all-targets` (74 tests)
against real PostgreSQL and an in-process NNTP server, plus the CLI demo.

| Area | Evidence |
|---|---|
| Crypto round-trips, tamper detection, wrong key rejection, nonce randomness, key separation, recovery kit, device enrollment, epoch rotation | `nntdrive-crypto` tests |
| yEnc, NZB, Message-IDs, dot-stuffing, auth, pooling, retries, concurrency bounds, provider fallback | `nntdrive-nntp` tests |
| Chunk bounds/determinism/empty files, RS reconstruction, manifest validation | `nntdrive-storage` unit tests |
| Encrypted upload/download, plaintext never on the wire, dedupe, shard loss, total loss, repair, refresh, wrong key, provider outage, version history | `nntdrive-storage/tests/storage.rs` |
| Scanner ignore rules, case collisions, path validation, rename detection, concurrent offline edits, conflict preservation, delete propagation | `nntdrive-sync` tests |
| Register/login, revoked device, admin authorization, tenant isolation, ciphertext upload, article proxy, dedupe lookup | `nntdrive-backend/tests/api.rs` |
| Docker image build, Compose stack, healthcheck, admin page, CLI bootstrap, admin API | ✅ verified locally (image built, stack started, `/healthz` 200, admin stats returned) |
| Flutter client analysis/tests, Linux desktop bundle, Android debug APK | ✅ `flutter analyze` clean, 2 tests pass, both artifacts built |

Run it yourself:

```bash
export TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/nntdrive_test
cargo test --workspace --all-targets
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
| 3. Desktop synchronization | **Engine done and tested; client build verified; UI not wired to crypto/sync** |
| 4. Virtual filesystem | **Not implemented** (WinFsp/FUSE design only) |
| 5. Mobile clients | **Android UI shell builds; iOS unbuilt; no DocumentsProvider/File Provider/photo backup** |
| 6. Sharing & production readiness | **Partial**: backend, admin dashboard, auth, jobs, Docker, backups, CI done; sharing/link endpoints absent; hardening/audit pending |

## What is intentionally not claimed

- Usenet retention is not guaranteed; the system reports unrecoverable data.
- Posted articles cannot be reliably physically deleted. Deleting a file only
  removes the logical index/tombstones the manifest; copies remain on Usenet and
  may be retrievable by someone who recorded Message-IDs.
- The backend is not trusted with plaintext; do not add a server-side decrypt
  path.
- No security audit. No production durability claim.
- Flutter *source scaffold* is not a working client. `docs/CLIENTS.md` has the
  exact missing integration.

## Immediate next tasks (in order)

1. **Rust↔Dart bridge**: expose `KeyFile::unlock`, `derive_auth_verifier`,
   chunking/prepare/publish, manifest seal/open, and the sync engine over a
   stable FFI (flutter_rust_bridge or a hand-written C ABI). Add Android NDK,
   iOS, Windows and Linux build wiring; then replace `NativeCryptoService`
   stubs. The Dart UI already calls a `CryptoService` interface.
2. **Sync backend adapter** implementing `nntdrive_sync::Remote` over the HTTP
   API (`/files`, `/chunks`, `/files/:id/manifest`, `/articles`), including
   conflict actions and SSE cursors.
3. **AMK epoch rotation** on device revocation (client command + keyring update);
   currently the backend only tells the client rotation is required.
4. **Sharing**: complete folder share endpoints and per-share wrapped keys, link
   tokens with password/expiry; share the AMK-derived folder key without exposing
   the AMK.
5. **Virtual drives**: FUSE (Linux) and WinFsp (Windows) adapters with range
   reads, write-back cache, offline pinning and safe interrupted writes.
6. **Mobile integrations**: Android DocumentsProvider + WorkManager/JobScheduler;
   iOS File Provider extension + BGTaskScheduler with honest background limits.
7. **Security review**, fuzzing of article/yEnc parsers, rate limiting at the
   proxy, password reset policy, audit logging coverage.
8. **Tests to add**: cross-machine sync over the real HTTP API, interrupted
   upload/download, huge-file memory ceiling measurement, replayed manifest,
   provider backbone correlation, restore-from-dump automation.

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
- Client CI jobs are non-blocking because the Flutter scaffold is not a working
  client yet.
