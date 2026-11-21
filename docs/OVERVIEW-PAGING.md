# Incremental overview result loading (#79)

## Production path

The Not synced screen now uses `SyncController.consumeOverviewPages` →
`buildIncrementalUnsyncedOverview` → incremental `SyncOverviewPage` publications.
It automatically consumes every result page; it does not stop at the legacy
10,000 native-action or 20,000 retained-row caps. No idle cursor is left waiting
for a user to click Load more. `ListView.builder` remains virtualised.

Every result batch is mapped, ordered and projected on entry-only workers once.
Exclusions are emitted once in batches of at most 256, after the first native
page establishes that the root is not blocked/active. Historical structured
errors are frozen for all roots before the first await, indexed once per root
on a worker, then only exact source/destination matches for the current bounded
page are passed to mapping. Current conflicts still outrank historical errors.
Actions use collision annotations computed against the **complete** collision
set, including move destinations and evidence delivered on later pages.

Immutable chunked all/status/folder/combined projections append each prepared
batch without sorting, copying or projecting the accumulated rows again. Counts
cover **loaded mapped rows**, not native record totals. Partial snapshots are
explicitly labelled “loaded so far” and never claim an empty comparison means
in sync. The terminal publication has final loaded counts; a failed/missing tail
retains the loaded rows and an incomplete warning/notice. Refresh retries the
comparison. Old publications remain immutable. Folder/status filters include
later pages, including rows beyond 20,000.

Rows are appended in cursor-delivery order, with ordering **within** each batch;
the growing list is not globally re-sorted. This intentionally avoids repeated
whole-list sorting and shifting already published rows. The legacy
`buildUnsyncedOverview` keeps its cap/global-sort compatibility contract.

## Compatibility and safety boundary

`SyncEngine::inspect` and `nntdrive_sync_inspect` remain compatible, including
legacy truncation. `SyncEngine::inspect_overview` completes exactly one full
read-only scan, remote snapshot, folder-move check and reconciliation before
returning an owned `InspectionCursor`. No preliminary actions are exposed.
Root/scan failure returns only typed blocked metadata; journal/remote failure
never creates a cursor. Pending identity-based directory moves still return no
per-file actions and show the existing explanatory notice.

The cursor retains the complete snapshot in process RAM. Initial scanning,
reconciliation and construction are whole-tree costs. Paging bounds transferred
**record counts**, not total memory or individual path/record byte sizes. Each
`next_page` moves records once without repeating remote/filesystem reads.

## Additive JSON C ABI

- `nntdrive_sync_overview_open(handle, request)` accepts existing inspection
  fields plus integer `pageSize` (1..256, default 256). It returns `cursor`
  after complete comparison. One opening/live cursor per unlocked handle is
  admitted; a concurrent open fails rather than duplicating work.
- `nntdrive_sync_overview_page(handle, request)` takes
  `{"cursor": 123, "operation": "next"}` or `"operation": "close"`.
- Owned strings retain existing `ok`/`error` and exactly-once
  `nntdrive_string_free` semantics. Calls run off the UI isolate.
- Pages contain `items`, `skipped`, `case_collisions`, `filesystem_blocked`,
  `journal_available`, `folder_moves_pending`, `totals`, `delivered`, `done`.
  The **sum** of the three array lengths never exceeds `pageSize`. Totals and
  delivered count native records, **not** UI rows or status counts.
- Items add `case_collision`, computed against all collision pairs and both
  source/destination paths. Pair pages alone cannot establish action safety.
- Delivery order is actions, current skips, collision pairs, exactly once.
  Empty/blocked snapshots still return a terminal metadata page.
- Completion frees the slot. Close is idempotent after completion. Foreign/stale
  tokens cannot advance or close a different slot. Failed opens/panics release
  reservations. Key revocation drops the slot and rejects late publication,
  under key-registry-before-cursor-registry lock ordering.

`NativeBridge.syncOverviewPagesAsync` owns the producer, awaited consumers and
finally-close inside session drain. Each native call uses a top-level worker
with primitive captures. The controller owns permission/journal admission and
the entire consumption workflow inside its existing drain. Cancellation is
checked at async boundaries; admitted native/mapping work is awaited, never
raced/abandoned. Page disposal cancels later stages and publication. Existing
single-flight/coalesced refresh and explicit retry/conflict/reveal actions remain.
Raw C callers must explicitly close abandoned cursors.

## Costs and limits

This is **result pagination, not incremental filesystem scanning** or proof of
an installed performance improvement. The complete native snapshot, frozen
required report paths, historical-error index and retained UI rows still cost
O(tree/results) memory. Error-index construction transfers the frozen per-root
report once. Caller work includes bounded page decoding-result transfer and
endpoint selection, chunk-metadata/group-map copying, folder-summary/notice
publication and Flutter rebuilding. Persistent chunk-reference lists are copied
on append; row data is not. Worker startup/message copies remain costs. No
per-record byte cap, interruption of an admitted scan or global exclusion of
inspection versus sync is claimed. Installed/manual large-tree responsiveness,
TalkBack and platform permission checks remain #65.

## Live queued items of a running sync

A running folder no longer collapses to one Pending summary row. Before the
first action is applied, `SyncEngine::run_once` reports its complete
reconciliation plan through a client-local `PlanObserver`: bounded batches of
at most 256 items plus the complete action total, in at most 4096 notified
items. Blocked case-collision paths are excluded because they are never
attempted. The `nntdrive_sync_request` callback emits the batch as
`{"phase":"plan","items":[...],"total":N}` using the same item shape as the
read-only comparison (`kind`, `path`, `path_to`, `size`, `is_dir`).

`SyncFolderConfig.activePlan` retains at most 1024 entries plus the reported
total and is reset at the start and end of every run; transfer events only mark
which planned path is moving now. The overview lists one Pending row per queued
path (Conflicts keep the Conflict status), with the current phase in the reason
("Uploading this file.", "Waiting to download this file.", ...). A capped plan
sets the existing truncation flag and states how many queued items are shown.

The scan that precedes reconciliation also reports progress: `SyncEngine` walks
the tree through a bounded `ScanObserver` (batches of at most 64 examined paths,
at most 4096 paths forwarded per run, each with `path` and `is_dir`), and
`nntdrive_sync_request` emits `{"phase":"scan","items":[...]}`. The client keeps
the first 256 entries, still counts every reported path, and lists them as
Pending rows with the reason "Scanning this folder."; queued plan rows replace
them as soon as the plan arrives.

The remote-snapshot step that follows reports progress the same way. The
`Remote` trait's default `snapshot_observed` simply returns `snapshot()`, and
transports that can list incrementally (the HTTP remote does) override it to
report the decrypted paths they have compared through a bounded
`SnapshotObserver`: batches of at most 64 paths (`SNAPSHOT_PROGRESS_BATCH`), at
most 4096 forwarded per run, never a selective-sync exclusion. The FFI emits
`{"phase":"compare","items":[...]}`, the client drops the scan rows on the first
compare batch, keeps the first 256 compared paths and counts the rest, and lists
them as Pending rows with the reason "Comparing with the remote copy.". An empty
remote folder keeps one root row so the folder stays visible while it compares.
Scan and compare batches are client-local and never leave the device; installed
responsiveness and TalkBack acceptance remain unverified under #65.

## Verification

Pinned isolated `bash scripts/dev-check.sh rust` passed formatting, workspace
check, Clippy with warnings denied and **186 Rust tests** (one intentionally
ignored subprocess helper; real disposable PostgreSQL was queried and used).
Final `bash scripts/dev-check.sh flutter` rebuilt release FFI, passed clean
analysis and **576 Flutter tests** (four existing platform skips), exiting 0.
The earlier combined canonical `all` also exited 0; the final affected wrappers
were rerun after the last code/test changes.
Focused sync/FFI verification also passed **48 sync + 9 FFI tests**, including
foreign/stale/locked cursor rejection, bounded sizes, failed-open/panic cleanup,
revocation during opening and rejection of late publication.

The real native/loopback fixture creates **20,017** local files and exercises the
default controller → native cursor → incremental builder, with one opaque-ID-only
HTTP listing, exact-once full reachability, bounded publication increments,
matching folder/status counts and no journal/local-file mutation. A suspended
mapping fixture proves controller drain waits and late admission is rejected;
additional real bridge tests cover backpressure, cancellation, errors and retry.
The widget fixture displays the first row before terminal completion, then filters
to a final-page row beyond 20,000; other tests cover incomplete counts, blocked/
active roots, active-admission races, endpoint failures/conflicts, immutable old
snapshots, per-root notice deduplication and page disposal.

The same native/controller fixture through the original legacy production route
failed with **10,000** rows instead of 20,017. Suppressing incremental publication
failed the bounded-work/publication test; reversing collision annotations failed
with **Pending instead of Blocked** for a destination whose collision evidence
arrives later. Temporary changes were restored before the final passing checks.
SDK Git-tag-fetch advisories in the isolated Flutter image do not indicate the
wrapper's exit status; no SDK permissions/resource guards were changed.
