# Project status

## Markdown update notes (#154)

Desktop and Android update prompts share native, selectable CommonMark notes:
headings, paragraphs, lists, emphasis, inline/fenced code, quotes, rules and
explicit external HTTPS links. The common history viewport stays scrollable
within 320 logical pixels. HTML is literal text; image nodes become inert alt
text before widget creation. Invalid/unsafe links are ignored, launcher failures
are contained, and parse/build failures fall back to the original selectable
body. Desktop version sections and omitted-release counts are unchanged.

Verified in the pinned isolated wrapper: dependency fetch, release FFI build,
clean Flutter analysis and **485 passing tests / 4 platform skips**. New tests
include the published v0.27.8 body, syntax/security/fallback checks, Copy selection,
light/dark 200% text scaling and actual desktop/Android dialogs with empty,
single and long notes. Restoring the original prompts fails five focused tests;
removing HTTPS enforcement fails two, and removing fallback fails one. All
sabotage was restored before the canonical successful run. Installed browser
launches and Windows/Linux/Android manual visual/update acceptance remain
unverified; channel mocks do not prove native OS behavior. See
[release-note policy, dependencies and verification](RELEASE-NOTES.md).

## Android back navigation (#78 partial)

Android system back in the file browser now leaves one folder at a time and only
lets the app close at the account root; the app-bar control uses the same path and
is labelled **Up one folder**. Opening a folder keeps its decrypted name in the
title, because the trail now retains the names it was opened under instead of
being cleared by each listing. Back inside the rename or new-folder dialog asks
**Discard your text?** rather than discarding typed input silently. Verified with
`flutter analyze` (clean) and the full Flutter suite (269 passed, 4 platform
skips) in the pinned isolated wrapper, including a new widget regression that
fails when the folder scope is removed and a dialog regression that fails when
the discard guard is removed. Predictive-back preview for the folder trail is not
animated (Flutter suppresses the system preview for a route that cannot pop), and
the gesture plus the dialogs are unverified on a real Android device — that
installed pass stays open on
[#78](https://github.com/ravand1990/nntdrive/issues/78). See
[navigation behaviour](CLIENTS.md#navigation-and-back-behaviour-78-partial).

## Unsynced-items overview (#79)

The production Not synced screen now consumes complete native comparisons in
sequential, session/controller-owned pages instead of dropping results at the
legacy 10,000-action/20,000-row caps. Actions, current skips and collision pairs
share a maximum 256-record native page. Complete scanning, remote snapshot,
folder-move checks and reconciliation finish before the first page; action
collision annotations cover the complete evidence and both move endpoints.

Each bounded page is mapped, ordered and projected off-isolate once. Exclusions
are emitted once in bounded batches; historical errors are indexed once per
frozen root and only current-page exact endpoint matches reach mapping. Immutable
chunked projections append rows without repeated whole-result sorting/copying.
Rows preserve delivery order with within-batch ordering, not global sorting.
The page publishes loaded rows/counts while consumption continues, labels partial
counts explicitly, and filters include all later pages. Empty/incomplete results
never claim everything is synced. Failed tails retain an incomplete warning and
can be refreshed. Active-root, blocked-root, conflict/error precedence, explicit
actions, single-flight refresh, cancellation and admitted-work drain remain.

`SyncEngine::inspect`/the legacy ABI and capped overview builder retain their
compatibility contracts. Cursors have one opening/live slot per unlocked handle
and are freed on completion, close or revoke; late opening cannot republish after
revoke. Admitted consumers/finally-close are awaited before shutdown drains.
See [API, costs and verification](OVERVIEW-PAGING.md). Final pinned canonical
Rust checks passed formatting/check/Clippy and 186 tests (one helper ignored);
canonical Flutter rebuilt release FFI, passed clean analysis and 576 tests with
four existing platform skips. Original-route 10,000/20,017 truncation and
publication/collision sabotage failures were verified before restored green runs.

A running folder now lists its queued work instead of one summary row: before
the first action the engine reports its complete reconciliation plan in bounded
batches (256 items per event, at most 4096 items, each with the complete total),
and the client lists one non-retryable Pending row per queued path with its
phase as the reason. The preceding scan/snapshot phases still show the single
"Sync is running." root row, and installed performance/permissions/TalkBack
acceptance remain unverified under #65.

This is bounded **result loading**, not incremental filesystem scanning or a
measured/installed speedup. Native comparison, required report freezing/indexing,
retained result RAM, caller merges/chunk metadata and worker transfer/startup
remain costs. Already admitted scans are not interrupted and inspection is not
globally serialized against sync.

### Earlier overview slices and verification history

The following records describe the previously shipped capped builder and other
retained contracts; the production pagination path and current costs above
supersede their whole-plan/global-cap descriptions.

Running folders now contribute one non-retryable **Pending** observation, using
the exact nonterminal upload/download progress path or a root summary when no
meaningful current transfer exists. Only scalar path/direction/completion fields
are copied; the native event schema has no scanning/reconciliation phase.
Known direction selects diagnostic-free Uploading/Downloading text, otherwise
the root says Sync is running. Historical failures and stale access flags do not
override active evidence. Every folder's initial evidence is frozen before the
first await; later sync admission upgrades an idle snapshot without replacing its
display configuration. Running folders skip inspection, with controller rechecks
after OS permission and journal-path awaits. A local `sync_running` marker is
active evidence, never an empty successful comparison. Counts/filtering and the
global cap cover retained observations only. A notice states that not all active
descendants are enumerated and full comparison awaits an idle refresh. This is
refresh-time evidence, not continuous per-byte updates or a cross-page lock: a
native inspection already admitted is not interrupted if sync subsequently starts.
Native incremental scanning and installed acceptance (#65) remain unfinished.

Active-evidence verification: ten deterministic builder/controller regressions
failed against the original code before implementation. The focused suite now
passes eleven tests including the rendered Pending row, idle-refresh explanation
and absent retry action. Canonical `bash scripts/dev-check.sh flutter` exited 0:
pinned Flutter 3.47.9/Dart 3.13.7, release FFI build, clean analysis, 560 tests
passed and four skipped. This is not installed-device or frame-time acceptance.

Closing the Not synced page now cancels its active refresh at asynchronous
stage boundaries. The builder checks before/after each folder inspection,
mapping, final ordering and projection, and before initial report freezing.
Already admitted work remains awaited, including a late failure; cancellation
does not become a filesystem-failure notice or publish a partial overview.
Each later independent refresh owns a fresh token. This avoids starting later
folders/workers after disposal, but cannot interrupt an admitted native scan,
worker, synchronous report freeze or result merge. It does not establish
incremental inspection, cross-page inspection exclusion or installed speedup;
installed lifecycle acceptance remains Backlog #65.

The sync page now opens a device-local **Not synced** view. For every enabled
idle sync folder it asks the Rust sync engine for a read-only plan — the same
three-way reconciliation a real sync would apply — and lists each item with a
text status and a plain-language reason: **Cloud only**, **Local only**,
**Pending** (queued deletion, move, rename or revision adoption), **Failed**
(an exact source or rename/move destination path failed in the last completed
attempt, with its coded reason; current conflicts take precedence),
**Conflict**, **Skipped** (selective-sync exclusion or current engine inspection
skip, never a stale last-run skip) and
**Blocked** (storage access, unreadable/missing/invalid local trees, or two names
that differ only by letter case).
Counts per status and per folder drive filter chips and a folder filter; the
list is virtualised and refreshed explicitly. At the global row limit, folder
and status counts describe only retained rows, including storage-permission
blocks; omitted rows set the truncation warning rather than inflating totals.
Filesystem root/scan failures
return diagnostic-free typed codes and one counted **Blocked** root row with
access/drive guidance; no partial items, inferred deletions or remote snapshot
are produced. An unreadable descendant blocks its whole tree, not an invented
per-file count. Network/journal comparison failures, a first-ever folder without
a completed sync, and pending folder moves remain notices, not filesystem
blocks or in-sync claims. Successful empty comparisons state that nothing is
waiting to sync. Retryable item rows offer a folder sync; blocked storage offers
an access grant where supported, and a conflict row offers
**Resolve conflict**, which reuses the Sync review choice (keep mine, keep
theirs or keep both) and applies it through the existing sync engine after
both sides are named. Each action reloads the plan, and the view reloads by
itself when a sync round finishes while it is open — a notification during a
running round is ignored — so the counts and rows belong to the current state.
A failed action is reported and the previous list stays on screen.

Page refreshes are single-flight: notifications arriving during a suspended
inspection coalesce into one follow-up, including changes during that follow-up.
An explicit check consumes an outstanding debounce timer. Automatic follow-ups
recheck sync/action admission; a later idle notification or the action's
completion refresh retries admission. Obsolete results/errors are suppressed
when a follow-up can run, and disposal drops queued work without publishing a
late result. This bounds overlapping page loads, not native scan size, continuous
freshness or inspection-versus-sync concurrency. Seven widget regressions cover
success/error follow-ups, disposal, timer consumption and busy/action admission;
the original code failed all five initial regressions. Canonical isolated
Flutter checks passed release FFI, clean analysis and 495 tests (four skips).
Installed behavior remains follow-up #65.

The inspection never uploads, downloads, deletes or writes the journal; it only
reads an existing journal read-only and may refresh the device-local remote-hash
cache. A pending or identity-based folder move yields the move notice and no
per-file items, because a plain path comparison would misreport a rename. Names,
paths and reasons stay on the device; the backend only serves the opaque listing
it already serves. On desktop, row details offer **Show local copy** after a
fresh check of the configured root, its ancestors and every relative component.
The click revalidates membership and the file/directory type, rejects links and
unsafe portable names, and opens only the containing directory (the directory
itself for a folder/root). Excluded local items can be revealed without syncing.
Missing or unsafe copies disable the action with a text explanation; Android
and iOS do not offer this desktop action. The older conflict-copy Show action
uses the same guarded, session-owned controller operation. Shutdown rejects
late launches and drains an already admitted launch attempt. The external file
manager can still race a hostile filesystem writer after validation; this is
local presence, not journal/revision equality. The overview covers one device;
cross-device presence is outside #79 scope and installed-device timing remains
unverified (follow-up #65).

Focused verification: `cargo test -p nntdrive-sync inspect` passed four new
engine regressions (plan without writes, clean result after a real sync, pending
folder move, deep conflict). `flutter test test/sync_overview_test.dart
test/sync_overview_page_test.dart` passed 17 tests with clean analysis; those
cover every status mapping, exact-path failure attribution, excluded/skipped
entries, case-collision blocking, storage-blocked folders, inspection failure,
counts/filtering/truncation, the widget list/filter/empty/retry states, the
post-action reload, the finished-round reload (and that a running round does not
trigger one), resolving a conflict through the shared choice dialog, a failed
action, and no conflict action without a resolver.

Reveal verification: the pinned canonical Flutter wrapper passed analysis and
386 tests (four Windows-only skips). Nineteen new filesystem/controller/widget
tests cover confined file/folder/root targets, absolute/traversal/portable-name
rejection, missing/wrong-type/link substitutions, removed folders, late session
admission and launch drain, redacted failure, exact row dispatch and refresh,
disabled missing-copy reveal and unsupported-platform UI. Replacing confinement
with the legacy unchecked join failed seven tests; ignoring the disabled-state
guard failed its widget regression. Both sabotages were restored. Injected
launchers do not establish installed Windows/Linux file-manager acceptance.

Filesystem-block verification: the pinned canonical Rust checks passed fmt,
workspace check, Clippy and 175 tests (one subprocess helper ignored; no database
skips); the canonical Flutter wrapper rebuilt the release FFI and passed analysis
and 398 tests (four Windows-only skips). Three new Rust tests cover actual
missing/file roots and chmod-denied roots/directories/files, no remote snapshot
or baseline mutation, continued real-sync failure before reconciliation, and
journal/remote error separation. Twelve new Flutter tests cover the real native
ABI/worker, zero HTTP for blocked trees and locked handles, redacted mapping,
root counts/filter/limit behavior, and the widget access-and-refresh action.
Full-path controller regressions additionally prove missing/file/chmod-denied
roots reach counted Blocked overview rows with the default storage access and
native runner, while ordinary sync still fails its listing preflight without
changing the previous report/time, journal or HTTP state. The controller keeps
Android's per-attempt OS permission gate (including revoked/absent status),
without issuing permission requests, and locked handles remain errors. These
four new native/controller regressions failed against the intercepted preflight;
the OS-gate regression covers denied/granted/revoked/absent channel responses.
The old engine failed two regressions and old overview mapping failed two;
the native fixture also exposed and verified the fixed unsendable bridge capture.
The bounded result is ordered once by folder name, status and relative path on
an entry-only worker isolate; redundant UI-isolate per-folder sorts are removed.
The builder waits for ordering before publishing rows. Five focused tests cover
worker execution, real builder dispatch without pre-sorting or inspector capture,
suspended publication, a 20,001-input/20,000-retained-row event-loop turn, and
empty/single-row metadata preservation. The original builder failed the yield
regression; replacing worker dispatch with caller-side `Future.sync` failed both
worker-location and yield regressions.

Plan-to-row mapping now also uses a separate top-level worker with only explicit
sendable config/report data, the native JSON plan and the remaining global row
budget. All folders' display config and relevant nested reports are frozen before
the first await. Mapping includes error-path indexing, exclusions, engine skips,
collision/status/reason selection, notices and retained-row folder counts. Folder
workers run sequentially; their retained output is bounded by the existing
20,000-row global default, then the existing single ordering worker sorts once.
No controller, inspector, session or native bridge is transferred. Publication
awaits mapping and ordering. New whole-builder tests cover a worker-only plan
getter with an unsendable inspector context, a single-row event turn (no ordering
worker), config/report mutation during inspection, and suspended mapping with
remaining-cap/folder-count preservation. The original caller-side builder failed
the location regression; caller-side `Future.sync` sabotage failed both location
and event-turn regressions, then the real worker was restored. Widget access /
refresh fixtures now explicitly allow real isolate event turns. The focused
mapping/ordering/overview/widget/native-inspection run passed 42 tests. Canonical
`bash scripts/dev-check.sh flutter` passed the release FFI build, clean analysis
and 443 Flutter tests (4 existing skips) on the pinned Linux toolchain.

After ordering, one snapshot-owned entry-only worker now prepares immutable
status counts and all/status/folder/combined row lists in one projection pass.
The production builder awaits this prepared result and does not rescan entries
on the caller. Page rebuilds and filter changes perform map lookups, preserving
the existing sorted order, retained-row cap and count/truncation semantics; no
worker is dispatched per rebuild. Unknown folder IDs return immutable empty
lists. The synchronous public constructor remains compatible for small direct
fixtures and prepares its projections once on the caller; it introduces no
isolate await into widget fake async. Production does not use that constructor.

Thirteen projection tests cover every status/folder combination, empty/unknown
IDs, caps 0–4 and the default 20,000 budget, immutable collections, no repeated
entry getters, a sendable getter rejecting the caller, real production dispatch
with an unsendable inspector context, suspended publication and a single-row
real event turn. Before implementation the rescan and mutable-input regressions
failed. Replacing only projection dispatch with `Future.sync` failed worker
location, production wiring and event-turn tests; the worker was restored.
Canonical `bash scripts/dev-check.sh flutter` then passed release FFI, clean
analysis and 456 Flutter tests (4 existing skips) on the pinned Linux toolchain.

Fresh-skip verification: the current read-only inspection supplies engine skips;
completed-attempt reports now contribute only structured errors. Empty, absent or
malformed current skips never resurrect historical paths. A typed blocked root
is handled before exclusions/skips consume its row budget, so replaced rows do
not leave a false truncation warning. Five new mapping tests failed on the old
behavior. A real controller/native/loopback regression creates and removes a
symlink between refreshes without syncing, checks fresh skip counts, unchanged
local bytes/report/journal and opaque-ID-only HTTP. The focused run passed 30
tests; the canonical pinned Flutter wrapper rebuilt release FFI, passed clean
analysis and 462 tests (4 existing Windows-only skips). Installed skip-refresh,
access and TalkBack acceptance remain #65; no incremental-scan claim is made.

Report input projection now copies only string `paths` and a string-or-null
`code` from each usable structured error before the first inspection await.
Unused nested diagnostic fields and malformed non-string path/code objects are
not recursively visited or transferred to the mapping worker. Error order,
last-error precedence, fallback reasons and exact-path matching are preserved;
all folders still capture independent path snapshots before inspection can
mutate their live reports. Two original-code regressions prove diagnostic
traversal is removed; a third checks cross-folder mutation isolation.

This is bounded retained output, not bounded input streaming or a whole-build
performance claim: native inspection is not incremental; required report-path
freezing and plan/report/entry isolate copying still occur, while result merging, folder
summary/notice freezing and publication remain caller-side. Projection lists
retain up to four references per row (all/status/folder/combined), plus group
maps; their construction/freezing runs on the worker. Worker startup/copy costs
and whole-plan temporary memory remain; no installed frame-time/speedup claim was
measured. Large-tree incremental inspection/responsiveness is still unfinished
under #79; installed permission/revocation and TalkBack acceptance remain #65.

## Account-wide encrypted-name search (#80)

### Final status publication worker

The final status-to-entry projection now runs once on a top-level worker over
completed sendable entry/status maps, inside the session-owned rebuild. It keeps
snapshot keys, original names/folded names and metadata unchanged; missing statuses
and `All` become `Unknown`, and extra status IDs are ignored. Only the complete
result is published after cancellation and final authorization checks. Failed
projection retains the previous searchable snapshot; close rejects late results
while drain still awaits completion. No inspector means no projection.

Canonical `dev-check.sh flutter` passed release FFI build, clean analysis and
**536 tests / four platform skips**. Six new tests cover production worker reads,
a real single-entry event turn, status semantics, failure/retry, single-flight
rebuild, suspended close/drain and final authorization. The production worker-read
regression failed on original code; `Future.sync` sabotage failed both execution
location and event-turn tests before restoration. Independent diff review found
no blocker. These are not installed-performance measurements (#93). The up-to-100k
entry map is transferred once for this stage, with transient old/new maps retained;
spawn/copy cost, earlier candidate merges, freezing and transport collection stay
separate caller-side costs. Cancellation waits for the admitted projection rather
than interrupting it. This does not establish whole-build isolation or freshness.

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
sync/configuration/disk changes. Filesystem inspection and ancestry walks remain
caller-side with cooperative yields; canonical comparison/grouping now run on a
worker as described below. No installed-device timing is claimed.

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
are covered. Installed-platform acceptance remains unverified. The later
report-freezing follow-up below removes whole-report JSON copying; immutable-set
construction, conflict scanning and filesystem inspection remain caller-side
scaling risks under #93; this is not an installed timing claim.

The bounded report-freezing follow-up replaces JSON serialization of entire
`SyncFolderConfig` objects with an explicit availability projection. All roots'
local/opaque-root identity, exclusions, discovered conflict paths, running flag,
progress path/completion and valid structured error string paths are copied before
the first await. Error records require string operation/code and a paths list;
non-string path elements and malformed records are ignored without descending
into them. Only known report/progress/error keys are read: arbitrary diagnostics,
nested lists and unknown map keys are neither enumerated nor copied. Historical
errors still use per-root immutable exact-path indexes, current conflicts win,
running roots suppress historical errors, and only the exact nonterminal progress
path is Syncing. Live browser report semantics and crypto/auth are unchanged.
Hostile MapBase and unused nested-list fixtures fail the original JSON copier;
second-root nested mutations during the first root's indexing await exercise
exclusions, conflicts, progress, running state, local root and error paths.
Canonical `dev-check.sh flutter-exec` analysis found no issues and the seven-file
search/status/native/listing/page/local-availability run passed **82 tests** with
the existing per-worktree native library. The original copier failed both hostile
fixtures (map-key enumeration and nested diagnostic traversal); the second-root
snapshot contract already passed. Cancellation during indexing remains covered.
This is a bounded field projection, not a bound on total required inputs:
freezing all roots still synchronously visits error records and copies string
paths/exclusions/conflicts before yielding. It checks cancellation during error
copying but cannot observe a later event until the indexing await. Index-set
construction, scalar worker input copies, ancestry walks, conflict/filesystem
inspection and final merges remain separate costs; no measured UI speedup,
whole-build isolation or installed-device performance is established (#80/#93).

The status-name follow-up moves portable-name validation, native canonical
comparison and complete sibling ambiguity grouping to one refresh-owned worker.
Sequential batches contain at most 128 scalar ID/parent/name records; the worker
retains counts privately, avoiding repeated copies of the growing snapshot.
Only after all batches does it return safe IDs (bounded by the 100k-node account
cap). Later invalid siblings invalidate the entire parent group; canonical
aliases across batches invalidate both spellings and their descendants through
unchanged caller-side ancestry checks. No bridge object, controller, cancellation
closure or key material is transferred; the comparison ABI needs no key handle.
The producer stops on cancellation, finishes the worker in a finally block and
awaits completion before session drain; late evidence cannot publish.
Canonical `dev-check.sh flutter-exec` formatting/analysis and the seven-file
search/native/listing/page/local-availability run passed **78 tests** using the
real warm native library. Deterministic worker-location, 128/128/1 ordering,
cross-batch alias/invalid-parent ancestry, failed-refresh retention and suspended
worker close/drain tests pass. The real Session/native/loopback fixture rejects
a late root alias across the 128 boundary, then restores local presence after
its removal, without plaintext requests. Replacing only this worker's
`Isolate.run` with `Future.sync` failed the location test; it was restored before
the green run. This is isolation/semantic evidence, not a speedup measurement.
Required-field freezing, scalar input copying, ancestry walks, conflict/filesystem
inspection and final snapshot merging remain caller-side; error-index construction
was also caller-side at this stage (moved by the follow-up below). Worker
spawn/message/final set-transfer costs and retained whole-snapshot grouping RAM
remain. Full cold-build isolation and installed-device performance are not
established.

The search-status error-index follow-up (#80) sends only validated frozen string
paths with a scalar root ordinal to one refresh-owned worker. Sequential batches
contain at most 128 paths, including within a single large error; acknowledgements
bound in-flight input without resending accumulated sets/maps. Deduplication and
final immutable per-root sets/list are constructed on that worker; even roots
with no valid paths receive an empty set (never absent-index browser fallback).
All roots' consumed operation/code/path evidence and config are still frozen
before the first await, malformed records are ignored, matching is exact and
conflict/running/active-transfer precedence is unchanged. Live browser consumers
remain unchanged. Cancellation and producer failures send finish and await worker
completion in finally; failed refreshes retain the previous complete snapshot and
session close/drain waits before discarding late results.
Deterministic sendable getter tests reject caller-isolate indexing, including the
production bounded-batch wiring. Replacing this worker's Isolate.run with
Future.sync fails the execution-location regression; restoring the original
caller-side indexSyncErrorPaths production dispatch fails the wiring regression
(expected 128/128/2 batches, observed none). Worker-finalization gates cover both
producer success and failure, and a suspended real-worker producer covers close
and session drain. The existing real Session/native/loopback status fixture,
all-roots mutation, malformed projection, root/exact-path isolation and browser
empty-versus-absent semantics remain covered. Pinned `dev-check.sh flutter`
passed **505 tests / four Windows-only skips**, clean analysis and a real release
FFI build. Required-field/path copying before await, bounded scalar batch assembly
and message transfer, ancestry/conflict/filesystem inspection, final map merging,
worker startup and retained whole-refresh error-path RAM remain costs. This is
execution-location/lifecycle evidence, not whole-build isolation, a measured UI
speedup or installed-device acceptance; #93 remains separate.

The search-status ancestry follow-up (#80) retains one scalar ID/parent/name/type
snapshot and the completed safe-ID set on a refresh-owned worker. Sequential
input and requested-output batches contain at most 128 entries. The worker walks
and validates parents, checks safe IDs and constructs root-first ancestries;
missing/non-directory parents, unsafe ancestors, cycles and excessive depth
remain unknown. The exact previous bound is preserved: up to 257 nodes may reach
a null parent, but attempting a 258th fails closed. Only one requested batch of
bounded ancestries is returned at a time, never all 100k full paths. Filesystem
availability inspection stays caller-side async IO and is awaited before the next
request. No native handle, HTTP client, controller or extra name decryption is
introduced. The entire operation remains inside the owned status inspection;
finally sends finish and awaits the worker after producer/consumer failures and
cancellation, so session close/drain still waits and rejects late publication.

Sendable getter guards cover worker execution and production ordered 128/128/1
input/request/output wiring. The original caller-side parent-map walk fails a
regression; replacing the new worker dispatch with Future.sync also fails its
execution-location test. Tests cover unsafe and malformed ancestry, exact depth
bound, cycles, bounded output, finalization gates, producer failure retaining the
previous snapshot and suspended close/drain. Pinned `dev-check.sh flutter` passed
**513 tests / four Windows-only skips**, clean analysis and the release FFI build.
The SDK's offline tag-fetch advisory did not fail checks. Scalar snapshot copying,
required config/report freezing, batch assembly/transfers, conflict/filesystem
inspection and final result merging remain caller-side; worker startup and a
second whole-snapshot scalar map plus safe IDs consume RAM. This is not a
measured speedup, full cold-build isolation or installed-device acceptance (#93).

The search-status conflict-index follow-up (#80) streams frozen root-ordinal/path
records to one refresh-owned worker in sequential acknowledged batches of at most
128. Exact membership, deduplication, same-directory `originalConflictPath`
inference, portable candidate validation and immutable per-root indexes are built
there once, not rescanned across all conflict paths for each search entry. Every
root receives prepared evidence, including empty indexes which never invoke the
live browser fallback. All roots still freeze before the first await. Discovery
is only a hint: each actual candidate's type and canonical path are checked again
at inspection time, every containing component remains confined, and a missing
ancestor returns before candidate lookup. No filesystem acceptance is cached;
missing originals remain non-revealable and conflict/error/transfer precedence is
unchanged. Browser consumers without prepared evidence retain live discovery.

An original-code counted-list regression observed 400 reads for five entries
against 40 conflict paths; prepared inspection reads those paths only once.
Sendable guarded batches prove off-caller execution and production 128/128/2
wiring. Caller-side Future.sync sabotage fails the location regression; omitting
prepared production evidence fails the root/precedence regression. Tests also
cover duplicates, invalid paths, exact spelling, root separation, empty-versus-
absent evidence, multiple candidates, deletion, directory/link substitution,
missing ancestors, worker finalization on producer success/failure, cancellation,
previous-snapshot retention and suspended close/drain. Pinned
`bash scripts/dev-check.sh flutter` passed **523 tests / four Windows-only skips**,
clean analysis and a real release FFI build; the SDK tag-fetch advisory did not
fail checks. Link-creation assertions in the new fixture are omitted on Windows
where they may require privileges. Required synchronous freezing, scalar input
assembly/message copies, per-candidate filesystem IO and validation, final merges,
worker startup and whole-refresh index RAM remain costs. Candidate lists for one
original can still require multiple filesystem probes. This is bounded streaming
and execution-location evidence, not bounded total index RAM, a measured UI
speedup, whole-build isolation or installed-device acceptance (#93).

The search-status filesystem follow-up (#80) moves local availability inspection
onto one refresh-owned port-loop worker. Frozen scalar root configuration and
prepared error/conflict indexes are sent once; the worker reconstructs its own
`SyncFolderConfig` instances, never receiving controllers, native libraries,
producer/cancellation closures or lifecycle completers. The ancestry consumer
awaits sequential batches of at most 128 entries before requesting more. Only
opaque IDs and scalar status enums return, not local paths or diagnostics.
Existing no-follow root/component checks, canonical confinement, portable path
validation, fresh conflict-copy probes, exclusions and status precedence are
unchanged. Filesystem acceptance is never cached and remains refresh-time
presence evidence, not journal equality or protection against hostile path swaps.

The parent canonical `dev-check.sh flutter` run rebuilt the release FFI, passed
clean analysis and **530 tests / four Windows skips**. The focused
`dev-check.sh flutter-exec` run passed clean analysis and **78 tests** across
`search*.dart` and `local_availability_test.dart`, using the warm native
library. A guarded sendable ancestry batch rejects caller-side reads: it failed
on the original per-entry production loop and also after replacing only the
filesystem worker's `Isolate.run` with `Future.sync`; both were restored before
the green run. Ordered 128/128/1 production batches, real files/deletion/links/
traversal/type mismatch, invalid batch rejection, success/failure finalization,
previous-snapshot retention and suspended filesystem-worker session close/drain
are covered. Existing real Session/native/loopback and conflict confinement
regressions also pass. Link creation in the new fixture is omitted on Windows,
where privileges may be required. Cancellation is checked before/after a batch;
an admitted batch finishes before drain returns. Required synchronous freezing,
scalar batch assembly, message copying, caller-side final merges, worker startup,
whole-refresh root/index RAM and per-candidate filesystem probe costs remain.
This is execution-location/security/lifecycle evidence, not a measured speedup,
whole-build isolation or installed-device acceptance; #93 remains separate.

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

The requested #80 search functions are implemented: account-wide name/metadata
search, combined filters, paths and refresh-time statuses, session-local recent
searches/saved filters, offline queries over the last complete RAM snapshot, and
account-close clearing. Installed 10k/100k responsiveness, keystroke-to-result
p95 and lifecycle/privacy acceptance remain explicitly unverified in #93, not a
feature-completion gate under `AGENTS.md` §5. The issue asks for a nonblocking
cold build, not complete isolation of every copy/merge; worker/yield regressions
support the implementation, not measured installed responsiveness. Persistent
encrypted indexes/history across restarts, incremental event updates and verified
journal/revision-equality badges are not requirements in #80's original scope;
none is claimed here. See the [acceptance map](CLIENTS.md#search-acceptance-and-limits)
for implementation/test evidence and exact limitations.

Query scanning/filtering and bounded top-200 ranking now run on
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

## Updates during device naming (#147)

Desktop and Android automatic checks share one lifecycle: startup checks can
present a dismissible update dialog over onboarding, and a failed feed read or
unavailable prompt remains pending for a post-confirmation retry. Confirmation
publishes the file UI before retrying and does not await dialog dismissal. The
daily timestamp is recorded only after a successful no-update result, explicit
version skip/Android version-code deferral, or acknowledged prompt. Opt-out is
rechecked after asynchronous feed/deferral work; disposed attempts cannot record
success. Startup checks run on each launch, periodic checks remain daily, and
manual checks share the selected platform's automatic lock. Installation paths
are unchanged. Unit and real app-shell widget regressions cover Linux/Android
platform selection, naming, Later and post-confirmation retry using injected
feeds and real native sealed device labels. Installed desktop/Android update
acceptance remains unverified.

## Private device naming (#140)

After unlock, the client requires an explicit device-name confirmation before
opening the file browser or starting uploads and scheduled sync. Android suggests
its configured device name or model; Windows uses its computer name/hostname;
Linux and other desktops use a meaningful hostname, otherwise a platform-labelled
fallback. The suggestion is editable and validated as a printable portable name
of at most 64 Unicode code points. It is not sent in authentication: the display
label lives in the existing client-sealed device-root `files.name_enc` and is
opened locally for the browser, spaces and device list.

Only a confirmation boolean is persisted, scoped to server/account/device/root
identity, not a plaintext label or label hash. Existing installations confirm on
first unlock after upgrade. Reopening the same confirmed identity does not prompt
again; signing in with a newly generated device ID does. Failure to initialize or
confirm the device space blocks entry rather than silently using the account root.
New uploads/folders from My files default to this device's space; opening Global
explicitly selects Global as the destination. Added sync folders also require the
device space. Renaming changes the encrypted label only, preserving node IDs,
content versions, sync relationships and existing local paths; legacy folders
still require the separate explicit move action below.

Onboarding recovery (#144) lists client-decrypted account spaces/root entries,
marks names colliding with the typed label, and offers an unused suggestion using
the native canonical collision comparison. Suggestions respect both the 64-code-
point and 255-UTF-8-byte limits; the exact chosen spelling is encrypted. Reload
and rejected confirmations retain typed input. Only a definite rename HTTP 409
is retried, once, after fresh read-only root identity and sibling snapshots;
other HTTP/transport errors and failed read-back are not retried. An acknowledged
write is confirmed only after opening the target envelope from a fresh file
listing, not a stale bootstrap label. Retries do not create roots or change node
IDs. These regressions do not establish affected-account or installed two-device
acceptance; no production account was accessed.

Migration 0008 scrubs live `devices.name` values to `Device` and installs a trigger
that normalizes legacy writers to that placeholder. Compatibility columns/API
fields remain, existing sealed root labels are preserved, and clients decrypt
them in RAM. Local subscription directory paths can contain a device label and
are not renamed when the label changes. Historical backups/WAL can retain old
plaintext names; old clients can still send names to older servers. Installed
platform/default-name and two-device acceptance are not established by this
documentation update; no new full-suite verification is claimed here.

## Account roots (#95 partial)

The backend can now hold one fixed **Global** root per account and one root per
registered device. `POST /roots` creates them idempotently from a client-sealed
name (`kind` is `global` or `device`); the client also sends the `node_id` it
generated, because the sealed name is bound to that ID and a server-chosen one
would be unopenable. The second caller — another client, a retry or a reinstall —
receives the existing node ID and envelope instead of a duplicate. A device root
requires a device-bound token and is keyed to the registered device ID. `GET
/roots` lists Global first, then every device root with its sealed label,
platform, last-seen time and a `stale` flag; a root stays listed after its device
goes offline or is revoked. The legacy `device_name` field is only `Device`;
display labels are decrypted locally. Device roots allow guarded encrypted label
rename; Global rename and all fixed-root move/delete or legacy name patches
remain forbidden with `409`. Favourite changes still work.

Both kinds are ordinary root-level folder nodes, so the existing browser and file
APIs already list and browse them. A signed-in client now **bootstraps them on
unlock**: it generates the node IDs, seals the root names for those IDs through
the native core, converges on existing roots, and lists them in an **Account
spaces** overview on the sync page. The overview marks each space as Global,
this device or another device, and shows offline or revoked devices instead of
hiding them; the spaces remain browsable folders in the library. A sync folder
added on a device is now created **inside that device's own space** rather than
at the account root, so two devices adding a folder with the same name no longer
share one remote path. If the device space is unavailable, adding a sync folder
fails closed instead of falling back to the account root. After device-name
confirmation, the **Global** space is subscribed automatically on
every client: it is mirrored into `<documents>/NNTDrive/Global`, so a new device
receives the account-wide space without the user adding a folder, and the space
is browsable as an ordinary folder in the library. Any other space can be
subscribed on demand from the spaces overview ("Sync to this device"), which
mirrors its tree into `<documents>/NNTDrive/<space name>`; "Stop syncing" removes
only the sync relationship and keeps the files, the remote space and the local
journal. Names are reduced to one safe directory component, so a device name
cannot escape the spaces directory, and a removed Global subscription stays
opted out across restarts until it is subscribed again. A move chosen while the
server is unreachable is now queued on this device and replayed on the next
unlock or sync: only opaque IDs and the sealed name are stored, replay re-runs the
guarded move so a changed source or a destination collision stops safely, and an
already-applied attempt is recognised instead of repeated. Entries that stop
retrying are shown on the sync page with a discard action. Selective sync now
says what it does to the shared space: when a sync folder mirrors **Global** and
subfolders are excluded, the selective-sync dialog explains that Global is no
longer fully shared, and the folder card shows a "Not fully shared" marker.
Excluded paths stop synchronizing in both directions, so the other devices no
longer receive their changes and their remote changes are not applied here;
nothing is deleted, and a device space or an unreadable space list is never
assumed to be Global. Cross-device moves are available from the move and copy
picker, which labels each space and confirms a move out of Global. A sync folder
created before account spaces existed still has its remote folder at the account
root, so the spaces overview lists it under **Folders outside your spaces** and
offers one explicit move into this device's space: the guarded move keeps the
node, sealed name, versions and subtree, stops on a destination collision, and
never targets Global or another device's space. Cross-device conflict handling
is now explicit: while the library shows a space whose device is offline or
revoked, a banner says that the space stays usable, that changes made here are
kept, and that a reconnecting device with its own unsynced change to the same
file keeps both versions as a conflict copy — nothing is overwritten. The sync
engine already reconciles by revision, and
`two_devices_roundtrip_create_modify_delete_and_conflict` in `crates/sync`
proves the concurrent offline-edit case; the banner is disclosure, it blocks
nothing. Existing accounts are migrated by the same idempotent bootstrap, and
pre-spaces sync folders stay listable and movable as described above, so this
issue has no remaining implementation scope. Installed two-device acceptance
stays with #65. See
[the root API](API.md#fixed-account-roots).

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

## NZB XML dependency follow-up (#16 partial, 2026-11-09)

The workspace resolves quick-xml **0.41.0**, the patched range for
[RUSTSEC-2026-0194](https://rustsec.org/advisories/RUSTSEC-2026-0194.html).
Duplicate-attribute checking stays enabled; attribute iterator errors on parsed
file, segment and metadata tags now propagate rather than being discarded.
Entity-reference events are accumulated with adjacent text to preserve metadata,
whitespace and normalized article IDs across the streaming API upgrade.
Five public-API integration tests cover generated/foreign NZBs, numeric and
predefined entities, multiple articles, malformed XML/attributes, and duplicate
attributes including fixed lists of 1, 16 and 128 extra attributes. Against the
original parser and quick-xml 0.37.5, both compatibility tests passed and three
validation tests failed. These are not a timing reproduction of the advisory:
the dependency remediation is established by the advisory and resolved version.
Canonical `bash scripts/dev-check.sh rust` passed formatting, workspace check,
Clippy (`-D warnings`) and **154 Rust tests**, with one existing ignored subprocess
helper and no PostgreSQL skips (isolated PostgreSQL 16.15). This bounded increment
is not full NZB schema validation, a performance benchmark or deployed acceptance.

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

The current release version is **v0.30.3** (2026-11-20); Cargo and Flutter
source versions are 0.30.3 (`0.30.3+82` for Flutter). Publication must be verified
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
| Real client SDK: register → create node → encrypted upload → manifest → download → decrypt → verify; dedupe; unauthorized access; interrupted upload retried without re-posting stored chunks; provider-rejected upload leaves no version; interrupted download leaves no destination or `.nntdrive-part` file | `crates/client/tests/e2e.rs`, `crates/client/tests/e2e/interruption.rs` |
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
| Versioned image release: tests → GHCR push (`0.30.3`, `0.30`, `latest`, `sha-*`) → GitHub release with Compose files, checksums and Linux/Android/Windows client builds | Tag-driven workflow; verify publication for the selected tag |
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

## Trash and restore (#81)

Deleting is logical and now recoverable. The backend records `deleted_at`, marks
the deleted node together with its still-live descendants (one shared timestamp,
so a deleted folder never leaves invisible orphaned children), and publishes a
`restore` event when an item comes back. `GET /trash` lists the account's deleted
top-level nodes with the retention deadline; `POST /files/{id}/restore` restores
the node and its deleted subtree, either in place, into a chosen live folder of
the same account, or at the account root when the original folder is gone. The
window comes from `NNTDRIVE_TRASH_RETENTION_DAYS` (default 30). A request past
the window returns `410`, and a daily `trash_purge` background job now enforces
the same deadline without a client: expired trashed top-level nodes lose their
metadata, versions and names for good, one account-scoped transaction and one
`purge` event each. The job skips a fixed account root or a subtree that still
holds live rows instead of failing the sweep, and it never retracts Usenet
articles.

The client has a **Trash** page in the file browser that decrypts names locally,
shows folder/size, deletion date and remaining days, offers one explicit
**Restore** action per row, and — when the original folder is gone — asks where
to put the item back: My files or any folder chosen in a fresh, locally
decrypted folder picker. Items past the window stay visible with **Cannot
restore**. Folder deletion is therefore enabled again: it moves the whole
subtree to the trash.

Items can also be removed for good: `DELETE /trash/{id}` deletes one trashed
node with its subtree and versions, and `DELETE /trash` empties the account's
trash. Both are tenant-scoped, take the account namespace lock, publish a
`purge` event per removed top-level node, and refuse a fixed account root, a
nested descendant of another trashed item, or a subtree that still holds live
files. The Trash page has a per-row **Delete permanently** action and an
**Empty trash** app-bar action, each behind its own confirmation dialog. This is
metadata-only: articles already posted to Usenet cannot be retracted, and the
dialogs say so.

Trash, restore, version history and rewind are merged. Installed desktop and Android acceptance of these flows is tracked in #138 and has not been run.

## Per-file version history (#81)

A file's **Version history** action opens a dialog listing that file's sealed
history newest first: each row shows when the content was committed and how
large it is, and the version the file currently points at is marked **Current
version**. Every earlier row can be downloaded under its own dated name, or
restored after an explicit confirmation that says the content current now stays
in the list.

Restoring moves only the file's current pointer through
`POST /files/{id}/versions/{revision}/restore`; nothing is uploaded, downloaded
or deleted, no version row or chunk reference is touched, so the content that
was current before can be restored in turn. The server re-checks that the
revision belongs to this file and account under the account namespace lock, and
publishes one `version` event with `restore: true` so other devices refresh
through their normal sync path. A folder, a trashed file and a version whose
content references are still pending are refused with a reason instead of being
restored. Names are still opened only on the device; the dialog receives the
decrypted name from the browser and the server only ever sees sealed envelopes.

The listing is bounded: at most the newest 200 versions are shown, with a note
when the cap is reached. Restoring an installed build and large-history
behaviour are not yet verified.

## Bulk rewind (#81)

`GET /rewind/preview` and `POST /rewind` put a folder or the whole account back
to an earlier date using versions that already exist. For every affected file
the current content pointer moves to the newest version committed at or before
the chosen date; newer versions, their chunk references and the trash are left
exactly as they were, so a rewind never deletes history, never retracts Usenet
articles and never resurrects deleted metadata. Files that did not exist yet at
that date are left alone instead of being deleted, and a version whose content
references are still pending is skipped rather than served unsafely.

The preview reports how many files would change, stay unchanged, were created
after the date or cannot be rewound yet, and returns one bounded page of sealed
names with the current and target revision ids. Applying sends only what the
user saw: every item is re-checked under the account namespace lock and a file
that changed meanwhile is refused with a reason instead of being silently
rewound. Each applied file publishes one `version` event with `rewind: true`, so
other devices refresh through their normal sync path.

The client offers **Rewind to an earlier date** from the Trash page with 1-day,
7-day, 30-day and pick-a-date presets. The plan is always shown first — the
changed files by decrypted name, the counts and the skipped items — and nothing
changes until the user confirms. The dialog states that versions after the date
remain in history and that posted Usenet copies cannot be retracted. Its scope
is the whole account by default and can be narrowed to one folder through the
same locally decrypted picker; choosing a different folder plans again, so the
user never confirms counts that belong to the previous scope.

A large plan is read page by page with the preview's keyset cursor, up to 25
pages in one planning pass; if changes remain after that, the dialog says so and
offers **Load more changes**. Rows already seen are skipped, so a repeated
cursor cannot loop or send one file twice. Confirming applies the loaded plan in
batches of at most 200 files — the backend's per-request limit — and the
dialogs report the summed result; if a later batch fails, the dialog says how
many files were already changed instead of claiming nothing happened.

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
- Tag-driven release pipeline: tests, GHCR image `0.30.3`/`0.30`/`latest`/`sha-*`,
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
  login autostart is opt-in and still requires the password after launch, and
  cold-process resumption remains future work. The unlock screen
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
10. **Test gaps**: multi-GB streaming, replayed manifest, provider backbone
    correlation, restore-from-dump automation, and Flutter integration tests
    that actually add a folder and synchronize. Interrupted upload/download now
    has client-level coverage in `crates/client/tests/e2e/interruption.rs`.

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
  intact (the manifest commits last). Retrying reuses chunks that were already
  stored. An interrupted download writes only to a `.nntdrive-part` file, which
  is removed on failure, so a partial or truncated destination is never left
  behind.
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
- Android has an in-app update check (#77 partial): it reads the same release
  feed, compares Android version codes from `nntdrive-<version>-android.json`,
  requires a `SHA256SUMS.txt` entry for the APK, and hands a verified download to
  the system installer, which always asks the user to confirm. Android 8+ needs
  the per-app install switch. No real in-place upgrade is claimed: the release APK
  is still debug-signed, so that needs the stable signing key and one recorded
  Android 11+ upgrade. iOS has no in-app updater; it requires App
  Store/TestFlight or a signed enterprise install.
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
