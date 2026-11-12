# Project status

## Account-wide encrypted-name search (#80 partial)

Search now supports refresh-time **All/Unknown/Local/Cloud only/Not covered/Syncing/
Conflict/Error** filters and badges, composed with existing filters and restored
from session-local recent/saved combinations. The file browser supplies loaded
sync configuration; the owned build freezes it, validates all sibling names and
ancestor collisions with native canonical comparison, and reuses confined local
availability checks without repeated HTTP listing per result. Only immutable
status enums enter query snapshots. No inspector/unloaded configuration means
unknown, never cloud-only. Failed inspection keeps the previous complete snapshot;
close cancels publication and session drain still awaits inspection completion.
Local is disk presence, not journal equality. Exact-path transfer/last-attempt
error evidence retains conflict precedence. Status is explicitly observed at
refresh, not invalidated/live-updated on sync start, and can become stale after
sync/configuration/disk changes. Caller-side filesystem inspection/canonical
comparisons yield cooperatively; no installed-device timing is claimed.

The refresh-time status increment passed the focused canonical-wrapper run of
`search_status_test.dart`, `search_page_test.dart`, `account_search_test.dart`,
`account_search_native_test.dart`, `search_listing_test.dart` and
`local_availability_test.dart`: **71 tests passed**, plus clean Flutter analysis.
Coverage includes real filesystem presence/missing/link/traversal and canonical
ancestor collisions, exact-path errors/conflict precedence, actual Session/native
loopback HTTP with plaintext-free requests, suspended inspector close/drain,
failed-build retention and widget status/clear/recent/save restoration. Temporarily
ignoring the scanner's status predicate failed the all-status combination test;
the predicate was restored before the passing regression run. Final parent
verification with `bash scripts/dev-check.sh flutter` passed **143 tests / four
Windows-only skips**, clean analysis and a real release FFI build; five wrapper
and ten agent-policy contracts passed. Independent review found no blocker;
test roots were canonicalized and privileged symlink assertions are omitted on Windows.
The subsequent error-path increment indexes each frozen root's structured errors
once into an immutable exact-path set, then discards that copied report before
per-entry inspection. Empty sets do not fall back to legacy scanning; browser
consumers without an index retain their existing dynamic report behavior. Index
construction yields/checks cancellation within reports and individual path lists.
Canonical `dev-check.sh flutter` passed **147 tests / four Windows-only skips**,
clean analysis and the release FFI build. A deterministic 500-entry fixture reads
zero report elements during status lookup; temporarily restoring legacy scanning
read 250,500 elements and failed, as did real-filesystem search status regressions.
Root isolation, frozen evidence, malformed errors, exact matching and precedence
are covered. Installed-platform acceptance remains unverified. Whole-report JSON
copying, immutable-set construction, conflict scanning and filesystem inspection
remain caller-side scaling risks under #93; this is not an installed timing claim.

Typing coalesces for 40 ms before dispatching a query worker (previously 180 ms,
which alone exceeded the ~150 ms keystroke-to-results target). Immediate query
actions consume any pending typing timer to avoid duplicate dispatch. Widget
regressions verify burst coalescing, dispatch within 50 ms of the final edit and
one query after explicit submission; both fail with the original behavior.
This bounds the UI scheduling delay only, not worker/paint latency or installed
10k/100k-entry performance acceptance, which remains #93.

The file browser's **Search all files** action builds an account/session-local
RAM index by recursively listing opaque folder IDs and opening authenticated
names through the existing native bridge on worker isolates, in sequential
batches of at most 128 (one batch in flight). The whole build awaits worker
completion inside SessionOperations, so close discards late results and drain
precedes key revocation. Name errors remain redacted; ciphertext formats/keys
are unchanged and decrypted names remain client RAM only. Queries stay local. Results rank exact,
prefix, word-substring and substring names, combine file/folder, extension, byte
size, namespace modification-date and real API favorite filters, show containing
folder paths/sizes, and navigate back through the existing browser. Recent and
saved filters are RAM-only (up to ten each). Explicit rebuild atomically replaces
the snapshot; failed/offline rebuild preserves the last complete snapshot. It may
be stale after remote or local mutations until rebuilt. Sign-out/Quit closes the
index before draining operations/revoking keys; delayed listings cannot decrypt
or republish afterward. No search index/query persistence, logging or telemetry
is added. Dart strings are garbage-collected, not guaranteed physically zeroized.

The original search increment's focused isolated Flutter run passed **10 tests** and clean analysis, including
real native encryption + loopback nested HTTP listings, no query/name/path in
requests, revoked-key rejection, delayed-response cancellation/drain, cross-session
clearing, atomic failure/offline reuse and widget navigation/filter reuse. A
100k-entry synthetic fixture verified bounded top-200 results and cooperative
yielding; 20 warm 10k-entry searches measured p95 **7750 microseconds** in that
container run (target <150 ms). Temporarily restoring folder-only traversal failed
the nested-listing regression; recursion was restored before the green run.

The worker-decryption follow-up passed the canonical isolated
`bash scripts/dev-check.sh flutter`: clean analysis and **104 passed / 4 skipped**
(existing platform-specific tests). The separate search-only run passed **16 tests**.
Coverage includes real authenticated worker decryption, ordered/bounded batches,
wrong/locked keys, substituted name AAD, real Session/loopback HTTP wiring,
suspended batch close/drain, redacted errors and atomic snapshot retention.
Restoring the synchronous build path failed the async-batch regression; replacing
`Isolate.run` with synchronous `Future.sync` failed the event-loop-yield regression.
Both sabotages were restored before the final canonical green run. These checks
do not establish installed-device cold-build latency or whole-build isolation.

The query-worker follow-up passed canonical `bash scripts/dev-check.sh flutter`:
clean analysis, **110 passed / 4 skipped**, real release FFI. Tests cover exact
filter boundaries/ties, 100k bounded results with real timer progress, newer-query
and snapshot-only invalidation, suspended close/drain and redacted failure/retry.
A scanner-entry isolate-identity check proves execution away from the caller;
actual Session + native/loopback HTTP search also yields a real event turn.
Replacing the query `Isolate.run` with `Future.sync` failed both regressions;
the worker was restored before this green run. Synthetic warm 10k-query p95 was
**34577 microseconds** (20 queries), including spawn/copy overhead, not installed
performance acceptance. Widget tests retain the real runner and wait bounded
real event turns rather than treating fake-frame settling as worker completion.

Warm explicit rebuilds reuse previously authenticated names only for the same
node ID and exact envelope in the last complete session snapshot. Fresh complete
listings still validate the tree and replace metadata, ancestry and membership;
changed names are reauthenticated in bounded batches. Failed candidates never
seed reuse. Native unlock authorization still precedes even an all-cached build.
The canonical isolated Flutter run passed **113 tests / 4 platform skips** with
clean analysis and real release FFI. New unit/native-loopback tests cover reduced
decryption, fresh metadata, moves, renames, removal, malformed/substituted
ciphertext and failed-refresh rollback. Both new unit regressions failed on the
old always-decrypt path; weakening reuse to ID-only failed the native regression.
The exact-envelope guard was restored before final verification. This is not
an event-driven or durable cache and does not reduce listing/parsing costs.

The cold-entry follow-up moves name lowercasing, SearchEntry construction and
bounded entry-map assembly to a top-level sendable worker helper. Each build
awaits sequential batches of at most 128, including reused names, without copying
the whole candidate into workers. Results merge only after the close/epoch check;
the complete candidate still publishes atomically and session drain includes the
worker await. Canonical isolated `bash scripts/dev-check.sh flutter` passed
**118 tests / 4 platform skips**, clean analysis and the real release FFI build.
The search unit/native-only run passed **28 tests**. Regressions cover worker
isolate identity and real event progress, ordered bounds, failed-entry snapshot
retention/retry and suspended close/drain. Actual Session/native/loopback tests
retain the default entry worker and verify folded results. Replacing its isolate
with Future.sync failed both execution-location/event tests; bypassing dispatch
with caller-side assembly failed both batch/lifecycle tests. Both mutations were
restored. Widget fixtures now build in runAsync to receive real worker messages.
These are not installed-device cold-build latency measurements.

The entry-refresh follow-up makes opening the search page rebuild the account
snapshot instead of only when the page happened to start without one, while the
previous complete RAM snapshot stays visible and searchable during that build.
Every successful complete publication (page-owned or triggered elsewhere, such
as the index's explicit rebuild) increments a monotonic `snapshotRevision`; the
page reruns its current text/type/extension/size/date/favorite query exactly once
per revision change and never on history, save or busy-state notifications. A
failed refresh keeps the last complete snapshot, shows an explicit "may be stale"
warning and clears it after a successful retry; nothing republishes after close.
Canonical isolated `bash scripts/dev-check.sh flutter` passed **124 tests / 4
platform skips** with clean analysis and the real release FFI build; the
search-only unit/widget/native run passed **36 tests**. New regressions cover
entry refresh after a ready fixture changes, external publication refreshing the
current filter, history not erasing results or re-querying, offline retention and
retry recovery, a delayed old query failing to erase a newer snapshot, close
during a pending refresh, and `snapshotRevision` advancing only on complete
publication (including an unchanged complete rebuild). These widget tests use
the repository's real worker runner with bounded real event turns; native
loopback HTTP tests remain in their separate file. No HTTP path was added, so no
new native fixture was required.

The listing-decode follow-up adds a search-only streamed HTTP path with a **64
MiB (67,108,864-byte) response body cap per folder** and at most **100k models
per listing**, compatible with a single-folder 100k-node account within that byte
budget. The cap checks Content-Length and actual HTTP-client-delivered bytes
(after automatic decompression); wide metadata can exceed it below 100k nodes.
UTF-8/JSON decode and `RemoteFile` construction run in a top-level worker that
captures only bytes. Unrelated listing behavior is unchanged. HTTP/parser errors
are redacted and malformed/oversized refreshes retain the last complete snapshot.
The session owns transport and parse completion, discarding results after close
and draining before key revocation. Canonical-wrapper targeted analysis was clean
and **35 search unit/native tests passed**, including six new regressions in a
separate real-loopback/native file (not a widget HTTP override). Coverage includes
caller-isolate rejection, 100k model acceptance/overflow, malformed UTF-8/JSON/model
rejection, exact byte-limit acceptance, Content-Length and chunked overflow,
redacted HTTP errors, auth, actual Session recursion, failed refresh retention,
locked admission and suspended parse close/drain. Temporarily replacing the decode
helper's `Isolate.run` with `Future.sync` failed the execution-location regression;
the worker was restored before the green run. Parent verification with
`bash scripts/dev-check.sh flutter` passed **130 tests / four platform skips**,
clean analysis and the real release FFI build; five wrapper and ten agent-policy
contracts also passed. These are not installed-device measurements (#93).

The bounded traversal follow-up moves per-batch parent/duplicate/count/depth
validation and ordered directory discovery into a top-level `Isolate.run` helper.
Only at most 128 opaque models plus expected parent, depth and remaining capacity
are sent; the accumulated candidate is never copied into this worker. Sequential
awaits stay inside session ownership, with an immediate epoch check before name
reuse/decryption and directory queue updates only after entry-map merge. Fresh
validation also runs on all-cached refreshes. Cross-batch/global membership checks
remain caller-side before decryption. Empty listings still skip validation batches;
nonempty listings at depth 256 remain allowed and depth 257 is rejected.
Targeted canonical-wrapper analysis was clean and **35 search unit/native tests
passed** against warm native artifacts. New coverage includes worker execution
location, ordered bounded dispatch/remaining capacity, cached malformed and
cross-batch duplicate refresh rejection before decryption, previous-snapshot
retention, depth/empty boundaries and suspended traversal close/drain. The native
loopback refresh also rejects cached malformed parents and cross-directory
duplicates without name opening. Replacing this helper's `Isolate.run` with
`Future.sync` failed the execution-location regression; the worker was restored.
After restoration, the canonical-wrapper search unit/native/listing/page run passed
**50 tests**, clean analysis and the changed-file formatter check. Parent verification
with `bash scripts/dev-check.sh flutter` passed **138 tests / four Windows skips**,
clean analysis and the real release FFI build; five wrapper and ten agent-policy
contracts also passed. Independent diff review found no blocking issue.
This is isolation evidence, not a measured speedup or installed-device acceptance.

This is not full #80 completion: search rows expose refresh-time availability,
not verified journal/revision equality or continuously current sync state.
Persistent encrypted offline indexing/history, incremental event updates,
installed-device performance and full cold-build responsiveness remain unverified
or unfinished. Query scanning/filtering and bounded top-200 ranking now run on
short-lived worker isolates, with at most one query worker in flight per index.
New queries/snapshot publication invalidate old results, superseded queued work
never dispatches, and close/drain owns every queued/running workflow through
completion. Only winning IDs return to the UI. Spawn/snapshot-copy overhead
remains per dispatched query; running scans finish rather than being killed,
with their RAM copies retained until then. Cold entry construction/folding and
bounded entry-map assembly run off-isolate, as do search-listing UTF-8/JSON decode
and opaque model construction, plus bounded traversal validation/discovery.
Transport byte collection/concatenation and worker
input copying, global membership checks, reuse selection, queue updates
and final candidate-map merges remain on the caller/UI isolate (with cooperative
~4 ms traversal slice yields).
Worker spawn/send overhead, temporary JSON/model memory and retained in-flight
names remain; this is not whole-build isolation. Index builds are
bounded to 100k entries/depth 256 and fail rather than publish a partial index;
large-folder network/decode cost is not established by the synthetic benchmark.
Freshness is explicit and entry/rebuild-triggered only: there is no polling, SSE
subscription, background sync or periodic re-listing; status evidence is only
observed during an explicit successful refresh, not live. Each refresh still
performs a complete bounded tree listing and decryption of
changed envelopes. Opening the page therefore always costs one full rebuild even
when nothing changed.
Content extraction is out of scope. See [client search](CLIENTS.md#account-wide-search-80-partial).

## Android folder access (#69, v0.7.0)

Shared-folder sync now explains and explicitly requests Android all-files access
for the current path-based Rust engine (legacy read/write grants on Android 6–10).
SAF URI access is not presented as POSIX access. Permission is rechecked before
sync; denial/revocation reports an error and offers retry on the same folder.
The app-private alternative needs no broad permission and uses a separate data
directory outside the live sync journals. A permission return cannot resurrect
a removed sync relationship. Names/content still use the existing encrypted path.

Scanner I/O failures abort before remote snapshot/reconciliation instead of
looking like missing/deleted local entries, including unreadable nested paths and
cached-hash files. Focused `nntdrive-sync` checks passed **38 tests** with one
existing ignored subprocess helper; a temporary restoration of skipped directory
errors failed the new regression as expected. **7 Flutter storage-access tests**
and analysis passed in the pinned isolated wrapper. Native Android path-policy
unit tests and a real private-folder/channel smoke are wired to hosted Android
jobs; their definitions are not execution evidence. Actual Android settings
grant/deny/revoke/restart and shared-folder encrypted transfer acceptance remains
unrun, tracked separately in [#75](https://github.com/ravand1990/nntdrive/issues/75).
See [access model and limits](CLIENTS.md#android-folder-access-69).

## Generate-once image deployment secrets (#62, v0.7.0)

The image-only `nntdrive-compose.py` launcher supplies a persisted OS-random
PostgreSQL password and 32-byte-base64 provider key, with independently explicit
first-boot overrides. `.env` may be empty or absent. Secret storage is 0600/0700,
locked, flushed and atomically published without overwrite; corrupt/insecure
state, override conflicts and missing secrets with existing project resources
fail closed. This is not rotation or existing-install migration; source Compose
and bare-backend defaults are unchanged. Releases from v0.7.0 include the launcher;
v0.6.0 assets do not. See the image guide's threat model.

Focused tests cover actual filesystem persistence, concurrent processes,
interrupted publication, explicit/empty/corrupt state, symlinks/permissions,
existing-data guard decisions, URL encoding and secret-free failure diagnostics.
Real Compose configuration tests cover dotenv precedence and rendering with no
`.env`/domain, plus the real launcher's read-only Docker `ps` path with absent then
empty `.env`. `python3 scripts/test-deployment-secrets.py` passed **13 tests**;
**10** filesystem/process tests also passed through the approved isolated
`dev-check.sh flutter-exec` wrapper. The absent-env rendering regression fails
against the original release Compose file. Live image pull, fresh backend/PostgreSQL startup, provider-password
read-back and Docker `down`/`up`/recreation acceptance have not been exercised;
filesystem tests are not a substitute for that live-stack acceptance.

## Live SSE authorization follow-up (#16 partial, 2026-11-09)

Live event streams revalidate the original hashed credential and tenant/device
binding against PostgreSQL before each batch, with a two-second poll/authorization
lease and fail-closed database deadlines. Resuming a backpressured batch after the
lease requires another check. See [security bounds](SECURITY.md#live-event-stream-authorization)
for admitted/buffered frame limits; this does not provide instantaneous revocation.
Five real already-open-body regressions (logout, token/device revoke, account
flag disable and natural expiry) failed against the original implementation by
receiving a post-invalidation change. They pass after the fix, along with token
identity replacement, backpressure, database-lock timeout and tenant-scoped
NULL-expiry/device-less-token cases, plus a digest Debug-redaction unit test.
Canonical `bash scripts/dev-check.sh rust` passed formatting, workspace check,
Clippy (`-D warnings`) and **149 Rust tests**, with one existing ignored subprocess
helper and no PostgreSQL skips (isolated PostgreSQL 16.15). These are router/body
and database checks, not deployed proxy-buffering or separate-process acceptance.

A bounded encrypted file/folder Copy SDK + guarded backend publication protocol
is implemented (#51), with atomic namespace/source-subtree guards and GC-safe
complete references. Flutter/FFI/UI supports explicit file and recursive folder
Copy with an encrypted destination picker and secret-free ambiguity/refresh
guidance. Folder trees publish all or nothing (256 nodes, depth 31, bounded
metadata/references). Copy-time renaming and durable retry receipts remain
unimplemented. Installed-client and two-device UI acceptance remain unverified.
See [Copy design](COPY-DESIGN.md) for bounds, retry policy and v1 key/dedupe limits.
The recursive Copy slice passed canonical `bash scripts/dev-check.sh all`: 123 Rust
passes (real PostgreSQL, no skips), release FFI build, clean Flutter analysis and
61 Flutter passes / 3 Windows-only skips. Weakening exact subtree equality to
subset matching failed the added-descendant HTTP regression (201 instead of 409);
it was restored before the complete run. These are isolated Linux-container results, not installed
client or two-device UI acceptance.
The quota-check follow-up reuses each Copy publication transaction's connection.
Three real HTTP regressions with a one-connection backend pool failed against
the original pool-based quota calls (bounded pool exhaustion), then passed after the fix:
file/folder quota denial and shared-content downloads, plus concurrent file/folder
publication. The follow-up canonical `all` run passed **126 Rust tests** (no skips),
release FFI build, clean Flutter analysis and **61 Flutter tests / 3 Windows-only
skips**; all **8 agent-policy tests** and `git diff --check` passed.

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

The current release version is **v0.9.0** (2026-11-12); Cargo and Flutter
source versions are 0.9.0 (`0.9.0+24` for Flutter). Publication must be verified
from the tag's Release workflow and attached assets. The historical
live-provider, desktop and release evidence below was not repeated by this
documentation run.

## NNT-001 partial desktop lifecycle and operation exclusion

Windows/Linux implement same-process close-to-tray with Open, generic status,
Pause/Resume and drain-before-lock Quit/sign-out. The application session owns one
controller; a per-settings-directory OS file lock is acquired before preferences
load. Native relaunch activation and tray-host checks avoid duplicate sessions
and intentionally un-restorable hidden windows. Linux release packaging and
unit/native/widget tests are narrower than installed desktop acceptance.
Autostart, cold-process unlock and mobile scheduling remain **unimplemented**;
#6 is not complete.

Whole sync rounds and conflict resolution now acquire an OS-backed SQLite lease
on `<journal>.operation-lock.sqlite`, independent of baseline transactions.
Competing updated owners of the same journal fail visibly; cancellation and
process-death recovery preserve baseline history. The per-journal lease is
separate from application ownership. See [background sync](BACKGROUND-SYNC.md)
for compatibility limits and remaining platform/security acceptance.

## Security-review increment (#16)

Account admission now uses a transaction-held PostgreSQL table gate shared by
API registration and CLI account/bootstrap commands. Independent backend pools
exercise first-account roles, registration policy, rollback and API/operator
exclusion against real PostgreSQL. yEnc validates declared sizes before fallible
allocation and stops at the declared decoded length; regressions cover oversized
headers, excess output, empty content and a bounded deterministic corpus. This
is targeted hardening, not a completed audit or coverage-guided fuzz campaign;
dependency triage and the broader review remain unfinished under #16.

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
| Versioned image release: tests → GHCR push (`0.9.0`, `0.9`, `latest`, `sha-*`) → GitHub release with Compose files, checksums and Linux/Android/Windows client builds | Tag-driven workflow; verify publication for the selected tag |
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

## Issue #51 partial file management

File/folder rows now offer native-encrypted rename, portable component validation,
fresh sibling collision checks and stale-entry rejection. Guarded rename now
atomically compares the opaque sibling snapshot under an account namespace lock
and emits a sync event; stale folders require refresh. Rename collision checks
now use native NFC/lowercase/NFC comparison while preserving the sealed spelling;
this is not full case folding or every filesystem's equality policy, and sync
scanner comparison is unchanged. Rows now inspect disk-derived local presence,
show explicit coverage/unknown/error/conflict-candidate labels,
and offer desktop reveal after fresh ancestry/confinement revalidation. Syncing
now marks only the exact active nonterminal transfer path; discovered preserved
copies also mark their same-directory originals after disk validation, including
missing original leaves without enabling reveal. Missing ancestors cannot infer
a pair. Refresh rescans conflict candidates. Presence alone is not a content-equality
claim. Idle regular files now gain a refresh-time equality tooltip only after a
read-only exact-path journal/revision/size check and fresh confined-file hashing;
unknown/failed checks and directories remain presence-only. This is not an atomic
filesystem snapshot or a durability guarantee. The sync core
now records matching remote revisions for identical independent additions/edits
after fresh local hash/type/size and non-link checks, with no content transfer.
Unknown remote revisions and failed revalidation leave the old baseline intact;
browser equality is checked separately on refresh. Structured client-local
per-item failures now identify exact involved paths without parsing raw diagnostics;
only these paths show Error from the last completed attempt (not while running),
with conflict precedence and safe local reveal preserved. Folder-wide exceptions
and scan skips are not attributed to individual rows. This is not completion:
The file browser now includes an encrypted destination picker and guarded moves
for files and folders, preserving opaque node identity, sealed name, content
history and subtree membership. Client-local canonical collisions and unreadable
destination names cancel before writes; concurrent source/destination changes
fail atomically under the account namespace lock. Bounded encrypted file/folder
Copy is implemented as described above; installed Windows/Linux plus two-device
acceptance remain outstanding. Legacy clients may
still introduce duplicate names after a guarded
rename. See [client details](CLIENTS.md#rename-in-the-file-browser-51-partial).

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
- Tag-driven release pipeline: tests, GHCR image `0.9.0`/`0.9`/`latest`/`sha-*`,
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
- Sync runs while the unlocked desktop process lives, including its hidden tray
  window on supported Windows/Linux desktops. It is not an independent service;
  autostart and cold-process resumption remain future work. The unlock screen
  explicitly shows sync paused while the vault is locked. Native regressions
  reject cold-start/revoked handles before network or journal access; unit tests
  and a Linux release build are not installed background-service acceptance.
  [Background sync](BACKGROUND-SYNC.md) records the unchanged password-required
  cold-start boundary and remaining desktop/mobile work.
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
8. **Provider & admin operations**: isolated live-stack/browser retention and GC
   acceptance and stronger alerts.
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
- Provider CRUD now applies a validated pool on the serving backend without a
  restart. Active storage operations pin their old snapshot. Multi-backend
  invalidation is not implemented; deploy one backend process. This is partial
  #15 only: isolated live-stack/browser acceptance remains open.
- Retention dashboard policy persists an article-age threshold in PostgreSQL;
  subsequent worker batches read it without restart. Maintenance results persist
  per batch with `done`, including unsuccessful refresh and unrecoverable counts.
  Mock-provider tests exercise reposting, loss, admin-only access and state
  recreation. Browser/live dev-stack acceptance is not yet performed. Results
  are not whole-sweep totals; running-job crash recovery/leases remain absent.
- `nntdrive_storage::store::platform_totals` casts aggregate sums to `bigint` because
  PostgreSQL returns `numeric`; keep casts when editing.
- Server-side plaintext search is intentionally absent. The client has a
  session-memory name/metadata index; content/full-text extraction is absent.
- Orphan cleanup is explicit per account with a grace period (minimum one day)
  and 1000-chunk batches. Complete references protect all retained versions;
  legacy/incomplete accounts refuse collection. Rust SDK backfill decrypts each
  historical manifest locally, including paginated/tombstoned versions. Successful
  opt-in permanently blocks legacy commits, also at the DB trigger boundary.
  Missing chunks fail commit atomically rather than publishing broken versions.
  Explicit unlocked Flutter reference backfill ships in bounded, retry-safe
  account-menu batches; isolated browser acceptance remains unperformed; see
  API compatibility notes before enabling. This deletes only local metadata.
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
  The hidden Windows PowerShell child uses an encoded command, closes unused
  input and retains startup stderr/PID diagnostics; the real-parent executable fixture covers replacement
  and a probe restart, not a packaged Flutter window or installed-release upgrade.
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
