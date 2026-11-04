# Project status

Last updated: 2026-11-04. This file is the handoff record for the next agent.

## Verified working

Everything below is exercised by `cargo test --workspace --all-targets` (82 tests)
against real PostgreSQL and an in-process NNTP server, plus the CLI demo.
Additional live checks were run against a real Eweka account (upload, download,
decrypt, verify) and through the Flutter FFI sync layer.

| Area | Evidence |
|---|---|
| Crypto round-trips, tamper detection, wrong key rejection, nonce randomness, key separation, recovery kit, device enrollment, epoch rotation | `nntdrive-crypto` tests |
| yEnc, NZB, Message-IDs, dot-stuffing, auth, pooling, retries, concurrency bounds, provider fallback | `nntdrive-nntp` tests |
| Chunk bounds/determinism/empty files, RS reconstruction, manifest validation | `nntdrive-storage` unit tests |
| Encrypted upload/download, plaintext never on the wire, dedupe, shard loss, total loss, repair, refresh, wrong key, provider outage, version history | `nntdrive-storage/tests/storage.rs` |
| Scanner ignore rules, case collisions, path validation, rename detection, concurrent offline edits, conflict preservation, delete propagation | `nntdrive-sync` tests |
| Register/login/logout, revoked device, admin authorization, tenant isolation, ciphertext upload, article proxy, dedupe lookup, shard locations | `nntdrive-backend/tests/api.rs` |
| Real client SDK: register → create node → encrypted upload → manifest → download → decrypt → verify; dedupe; unauthorized access | `crates/client/tests/e2e.rs` |
| Two-device sync: create/modify/delete propagation, conflict copies, independent multiple roots | `crates/client/tests/sync_e2e.rs` (real API + mock NNTP) |
| Dart ↔ Rust FFI sync: two local folders, upload/download/edit propagation against the live backend | `clients/flutter/tool/sync_smoke.dart` (verified) |
| Dart ↔ Rust FFI: account generation, keyfile unlock, name seal/open with wrong-key rejection | `clients/flutter/test/native_test.dart` + `crates/ffi` tests |
| First-run onboarding: setup status, first admin registration, one-time admin token, recovery code | backend tests + Flutter UI |
| Provider test: DNS/TLS/auth probe without posting; admin restart; article verification via retrieval provider | `nntdrive-backend/tests/api.rs`, live Eweka |
| Multi-folder UI: base + additional folders, 5-minute auto-sync, pause, manual sync, conflict copies | `clients/flutter/lib/sync_controller.dart`, `sync_page.dart`; FFI sync smoke |
| Real Eweka round-trip: post via `post.eweka.nl:563`, retrieve via `news.eweka.nl:563`, decrypt, verify hash | 4 KB live upload; both articles STAT-verified |
| Live deployment: dev Compose stack with mock NNTP; register/upload/download through the API | `crates/client/examples/smoke.rs` (verified) |
| Docker image build, Compose stack, healthcheck, admin page, CLI bootstrap, admin API | ✅ verified locally (image built, stack started, `/healthz` 200, admin stats returned) |
| Flutter client analyze/tests, Linux/Android/Windows release builds | ✅ clean analyze, Dart FFI tests pass; Linux/Windows bundles run, Android APK (~77 MB, debug-signed) embeds all ABIs |

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

Live checks against a real Eweka account (not the mock):

```
uploaded revision ... (1 new chunks, 2 articles)   # 4 KB test file
SMOKE_OK: upload, download, decrypt and verify succeeded
admin/articles/verify: 2/2 retrievable via eweka   # STAT through news.eweka.nl
```

Dart FFI sync smoke against the live backend + Eweka:

```
A sync: uploaded=1
B sync: downloaded=1
B edit sync: uploaded=1
A pull: downloaded=1
SYNC_FFI_SMOKE_OK
```

Eweka provider notes for the next agent: use `news.eweka.nl:563` (retrieval,
`retrieval_only`) and `post.eweka.nl:563` (posting, `posting_only`) with the same
credentials; posting must be enabled on the plan. The article `From` header must
be a valid internet address and Rustls needs an explicitly installed crypto
provider when both aws-lc-rs and ring are in the dependency graph.

## Recent implementation milestones

- Multi-folder sync integrated end-to-end: HTTP `Remote` adapter, per-folder
  SQLite journals, base + additional folders, automatic 5-minute runs, pause,
  manual sync, conflict copies, directory sync actions.
- First-run onboarding in the app: setup detection, first administrator, recovery
  code and one-time admin token; CLI `bootstrap` command and script.
- Admin dashboard: added provider test, recent-article verification, one-click
  graceful restart.
- Real Eweka upload/download fixed: host/port/TLS validation, posting host split,
  valid From header, Rustls provider selection.
- Flutter Windows release build and Android/Linux release artifacts verified.

## Phase status

| Phase | State |
|---|---|
| 1. Working storage engine | **Done and tested** (CLI demo uploads, downloads, decrypts, verifies) |
| 2. Self-healing storage | **Done and tested** (health, repair, refresh, snapshots via sealed manifests, simulated loss) |
| 3. Desktop synchronization | **Done for multi-folder bidirectional sync, automatic runs, conflicts and versions; virtual drives remain separate** |
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
- The client stores the password-wrapped keyfile in shared preferences; it is
  Argon2id-protected. The unused device-identity secret is no longer persisted.
  Move the keyfile to the platform keystore for a hardened build.
- Sync runs only while the desktop app is open (no background service yet) and
  each file is buffered in memory by the `Remote` adapter; very large files and
  true background sync are future work.
- Empty local folders are synced, but remote folder renames are currently seen
  as delete+recreate (content is preserved; history/path identity is not).
- The live Eweka account required separate retrieval/posting hosts and a valid
  `From` header. Other providers may need different ports or groups; use the
  dashboard Test and Verify actions before bulk uploads.

## Immediate next tasks (in order)

1. **Windows packaging**: the build is verified, but add code signing, an
   installer/updater and test on a clean Windows VM without the SDKs. The FFI
   DLL must ship next to the executable.
2. **iOS**: build the Rust static library as an XCFramework, add the File
   Provider extension and BGTaskScheduler integration; requires macOS.
3. **AMK epoch rotation** on device revocation (client command + keyring update);
   currently the backend only tells the client rotation is required.
4. **Sharing**: complete folder share endpoints and per-share wrapped keys, link
   tokens with password/expiry; share the AMK-derived folder key without exposing
   the AMK.
5. **Virtual drives**: FUSE (Linux) and WinFsp (Windows) adapters with range
   reads, write-back cache, offline pinning and safe interrupted writes.
6. **Mobile integrations**: Android DocumentsProvider + WorkManager/JobScheduler;
   iOS File Provider extension + BGTaskScheduler with honest background limits.
7. **Provider management**: the dashboard can add/delete/test providers and
   restart, but cannot edit an existing provider in place; add PATCH + live
   reload without restart where possible.
8. **Sync UX**: conflict review/merge screen, selective subfolder sync, per-file
   progress, and background sync outside the app process.
9. **Security review**, fuzzing of article/yEnc parsers, rate limiting at the
   proxy, password reset policy, audit logging coverage.
10. **Tests to add**: interrupted upload/download, huge-file memory ceiling
    measurement, replayed manifest, provider backbone correlation,
    restore-from-dump automation, Flutter integration tests for add-folder/sync.

## Known bugs / rough edges

- SSE only supports `Authorization` headers (fine for Dart/Flutter HTTP clients,
  not for browser `EventSource`). The app does not yet consume SSE; it refreshes
  on demand and after sync.
- Provider changes require a process restart (one click in the dashboard). There
  is no in-place edit form for existing provider rows yet.
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
- Client CI builds and tests Linux/Android; Windows/iOS jobs stay non-blocking
  (Windows is verified locally; iOS needs macOS).
- The app's "upload" of a new file creates the node first; if the upload fails it
  tombstones the node. An interrupted version upload leaves the previous version
  intact (the manifest commits last).
- Sync conflicts are preserved as files but there is no merge/review dialog yet.
- Remote folder renames are not detected as moves; they become delete + recreate.
- Sync currently keeps one SQLite journal per selected folder under the app
  support directory; uninstalling the app loses the baseline (the next sync may
  re-download or produce conflicts, never data loss).
