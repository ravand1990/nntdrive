# Project status

Last updated: 2026-11-06. This file is the handoff record for the next agent.

## NNT-016 verification snapshot (2026-11-05)

On 2026-11-05, `bash scripts/dev-check.sh all` on the main-based NNT-016
checkout passed formatting, workspace check, clippy with `-D warnings`, and
`cargo test --workspace --all-targets`: **93 Rust tests passed**, none failed,
ignored or database-skipped. The isolated PostgreSQL 16.15 query succeeded.
The same run built the release Rust FFI library, passed Flutter analyze with no
issues, and passed **12 Flutter tests**, including real native bridge tests.
Toolchains: Rust 1.99.1, Flutter 3.47.9, Dart 3.13.7. These counts describe
the dated NNT-016 checkout snapshot, before NNT-017 was integrated.

At the subsequently integrated NNT-017 PR head (`fff85a5`), exact-head Clients
run [42130387280](https://github.com/ravand1990/nntdrive/actions/runs/42130387280)
passed analyze and all **18 Flutter tests**, including updater tests, plus
Linux/Android/Windows builds and Android native smoke. Exact-head CI run
[42130387023](https://github.com/ravand1990/nntdrive/actions/runs/42130387023)
passed. NNT-017 changed only Flutter code; the 93 Rust tests above remain the
latest recorded Rust count, not a new post-merge run.

The latest published release is **v0.5.2** (2026-11-08); Cargo and Flutter
source versions are 0.5.2 (`0.5.2+9` for Flutter). The historical
live-provider, desktop and release evidence below was not repeated by this
documentation run.

## Verified working

Everything below is exercised by `cargo test --workspace --all-targets`
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
| Two-device sync: create/modify/delete propagation, conflict copies, independent multiple roots, selective-sync exclusions, remote file renames, node-ID folder moves, interrupted-move recovery and collision guards | `crates/client/tests/sync_e2e.rs` (real API + mock NNTP) |
| Dart ↔ Rust FFI sync: two local folders, upload/download/edit propagation against the live backend | `clients/flutter/tool/sync_smoke.dart` (verified) |
| Dart ↔ Rust FFI: account generation, keyfile unlock, name seal/open with wrong-key rejection | `clients/flutter/test/native_test.dart` + `crates/ffi` tests |
| First-run onboarding: setup status, first admin registration, one-time admin token, recovery code | backend tests + Flutter UI |
| Admin user/provider management: edit users (name, quota, role, status), provider CRUD with in-place edit, type dropdown, credential retention | `crates/backend/tests/api.rs`, embedded dashboard |
| Provider test: DNS/TLS/auth probe without posting; admin restart; article verification via retrieval provider | `nntdrive-backend/tests/api.rs`, live Eweka |
| Multi-folder UI: base + additional folders, 5-minute auto-sync, pause, manual sync, conflict copies, selective-sync exclusions, conflict review panel | `clients/flutter/lib/sync_controller.dart`, `sync_page.dart`; FFI sync smoke |
| Real Eweka round-trip: post via `post.eweka.nl:563`, retrieve via `news.eweka.nl:563`, decrypt, verify hash | 4 KB live upload; both articles STAT-verified |
| Live deployment: dev Compose stack with mock NNTP; register/upload/download through the API | `crates/client/examples/smoke.rs` (verified) |
| Docker image build, Compose stack, healthcheck, admin page, CLI bootstrap, admin API | ✅ verified locally (image built, stack started, `/healthz` 200, admin stats returned) |
| Versioned image release: tests → GHCR push (`0.5.2`, `0.5`, `latest`, `sha-*`) → GitHub release with Compose files, checksums and Linux/Android/Windows client builds | ✅ v0.5.2 published |
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
- Streaming sync and remote content-hash caching: files are transferred through
  the `Remote` adapter without whole-file buffering, and remote file renames are
  detected as local moves.
- Selective sync and conflict review: per-folder exclusions are applied to local
  scans and the remote snapshot, and the sync screen lists conflict copies with a
  review panel.
- Admin dashboard can edit users (name, quota, role, status) and providers in
  place, with a provider-type dropdown.
- Windows/Linux auto-update: every-launch plus daily GitHub release checks
  (opt-out disables both; deferred versions suppress prompts, not checks),
  serialized automatic/manual checks and prompts, in-app update settings
  (repository + optional read-only token for private releases), SHA-256
  verification, detached in-place replacement and restart.
- Tag-driven release pipeline: tests, GHCR image `0.5.2`/`0.5`/`latest`/`sha-*`,
  and a GitHub release with the image-only Compose files, `SHA256SUMS.txt` and
  Linux, Android and Windows client builds. The image is amd64 only; arm64 needs
  native runners or a longer QEMU build. iOS requires macOS/Xcode and is not
  published.

## Phase status

| Phase | State |
|---|---|
| 1. Working storage engine | **Done and tested** (CLI demo uploads, downloads, decrypts, verifies) |
| 2. Self-healing storage | **Done and tested** (health, repair, refresh, snapshots via sealed manifests, simulated loss) |
| 3. Desktop synchronization | **Core done: multi-folder bidirectional sync, automatic 5-min runs while open, streaming transfers, selective sync, explicit conflict resolution with recoverable copies, per-file logical byte progress, remote folder moves. Remaining: background service, virtual drives** |
| 4. Virtual filesystem | **Not implemented** (WinFsp/FUSE design only) |
| 5. Mobile clients | **Android app builds, browses and syncs (same Flutter UI); iOS unbuilt; no DocumentsProvider/File Provider/photo backup or reliable background sync** |
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
- Sync runs only while the desktop app is open (no background service yet), but
  files are streamed through the `Remote` adapter rather than held in memory.
  True background sync remains future work.
- Remote folder renames use persisted node IDs and remap the complete journal
  subtree, including empty directories. Old journals learn IDs on their first
  successful sync after upgrade; moves before that baseline are not inferred.
  Destination collisions or excluded-subtree intersections stop safely. A missing
  local source leaves that subtree for manual reconciliation and reports an
  error while unrelated paths continue. Remote file renames retain hash detection.
- The live Eweka account required separate retrieval/posting hosts and a valid
  `From` header. Other providers may need different ports or groups; use the
  dashboard Test and Verify actions before bulk uploads.

## Immediate next tasks (in order)

1. **Sync hardening & scale**:
   - run sync in a background service (desktop autostart) instead of only while
     the UI process is open;

   Per-file progress and explicit conflict actions are implemented (NNT-005);
   container Rust/Flutter suites and a two-device Dart FFI smoke exercise real
   HTTP + mock NNTP. New platform-specific release validation remains with CI.
2. **Secure local key storage**: move the password-wrapped keyfile from shared
   preferences into Keychain (iOS/macOS), Android Keystore, Windows Credential
   Manager and Secret Service (Linux); keep the recovery kit policy documented.
3. **Device revocation + AMK epoch rotation**: implement client-side rotation,
   re-wrap for remaining devices, and retain old epoch keys for old revisions;
   today the backend only instructs the client to rotate.
4. **Windows packaging**: code signing, installer/updater, and a clean-VM test
   without SDKs. The FFI DLL must ship next to the executable. Hosted Windows
   native tests/builds are now blocking; installer/restart validation remains open.
5. **iOS**: build the Rust static library as an XCFramework, add the File
   Provider extension and BGTaskScheduler integration; requires macOS.
6. **Sharing**: folder-share endpoints with per-share wrapped keys, public link
   tokens with password/expiry, and revocation/rotation that does not expose the
   AMK.
7. **Virtual drives and native mobile integration**: FUSE/WinFsp mounts,
   Android DocumentsProvider + WorkManager, iOS File Provider + background
   transfers, photo/video backup.
8. **Provider & admin operations**: live provider reload (edits still require a
   restart), retention settings UI, stronger alerts and orphaned-chunk garbage
   collection.
9. **Security review**: fuzz yEnc/NZB/article parsers, add proxy-level rate
   limiting guidance, password-reset policy, audit-log coverage and dependency
   review.
10. **Test gaps**: interrupted upload/download, multi-GB streaming, replayed
    manifest, provider backbone correlation, restore-from-dump automation, and
    Flutter integration tests that actually add a folder and synchronize.

## Known bugs / rough edges

- SSE only supports `Authorization` headers (fine for Dart/Flutter HTTP clients,
  not for browser `EventSource`). The app does not yet consume SSE; it refreshes
  on demand and after sync.
- Provider changes require a process restart (one click in the dashboard).
  Providers can be edited in place, but the running NNTP pool picks them up only
  after the restart.
- `nntdrive_storage::store::platform_totals` casts aggregate sums to `bigint` because
  PostgreSQL returns `numeric`; keep casts when editing.
- Full-text search is impossible server-side (names/content encrypted); the
  client must cache a decrypted index.
- Cleanup of orphaned chunks (upload aborted before commit) is not implemented.
  Add a job that deletes chunks unreferenced by any manifest after a grace period.
- No AMK rotation command yet; device revocation instructs the client but does
  not perform client-side key rotation automatically.
- The release image is `linux/amd64` only. Native arm runners or a successful
  QEMU build are needed for `linux/arm64`; no multi-arch manifest is published yet.
- Client CI builds Linux/Android/Windows; Windows native unit tests and release
  packaging are blocking. iOS is not currently built in CI and remains
  unimplemented. Android ABI packaging checks and the KVM native
  crypto/private-storage smoke are distinct; the smoke is not backend/sync E2E.
  See [CI coverage](CI.md)
  for exact contracts and unverified branch-protection enforcement.
- The app's "upload" of a new file creates the node first; if the upload fails it
  tombstones the node. An interrupted version upload leaves the previous version
  intact (the manifest commits last).
- Client auto-update runs only on Windows and Linux. It needs write access to the
  install directory. Public releases do not require a token; private release
  repositories require read access configured in update settings. Actual
  Windows/Linux replacement, restart and data/journal preservation acceptance
  remains tracked in NNT-103 (#28); implementation is not proof of that acceptance.
  Issue #49 adds awaited helper launch and Windows preflight acknowledgement,
  step diagnostics, backup/hash-verified replacement and attempted rollback.
  Native helper fixtures are distinct from the still-required installed-build
  update/restart/version/data and locked-file manual checks.
- Android and iOS have no in-app updater; Android requires the system package
  installer and iOS requires App Store/TestFlight or a signed enterprise install.
- Sync conflict review supports Keep mine (the preserved conflict copy), Keep
  theirs (the canonical path) and Keep both. Recovery/kept files remain synced;
  no version is deleted. Changed local hashes or remote revisions reject stale
  review. Partial failures may require sync and another review; this is not a
  distributed transaction or automatic content merge.
- Per-file progress counts logical plaintext bytes after chunk publication or
  deduplication, and after verified download writes, not encrypted wire traffic.
  A full byte count is not success until manifest commit / final verification.

- The sync `Remote` adapter caches remote content hashes on disk; without cached
  entries it fetches and decrypts manifests (bounded per run), so large first
  syncs do more network work. Folder moves use node IDs instead of content hashes.
- Sync folder selection uses the platform directory picker; Android’s picker is
  more restrictive than desktop, and background work while the app is closed is
  not scheduled yet.
- Sync currently keeps one SQLite journal per selected folder under the app
  support directory; uninstalling the app loses the baseline (the next sync may
  re-download or produce conflicts, never data loss).
