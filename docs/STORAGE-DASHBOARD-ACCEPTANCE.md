# Storage dashboard: implementation and acceptance evidence (#84)

Audited on **2026-11-24** against **v0.36.0** (`0d4c8c7`). This maps the
original [#84](https://github.com/ravand1990/nntdrive/issues/84) requirements to
integrated behavior; it is not another backlog or installed acceptance report.
The detailed limits and user contract remain in [CLIENTS.md](CLIENTS.md#storage-usage-84-first-slice).

## Requirement mapping

| Original requirement | Delivered contract | Automated evidence |
|---|---|---|
| Account total, top-level folder and file-type breakdown | Logical live-file listing bytes/counts; folder identities remain opaque internally; extension groups and top-20 plus exact remainder. History/trash/quota/physical bytes are excluded. | `storage_usage_test.dart`, `storage_usage_native_test.dart` |
| Local cache, synced data and pinned data | Separately measured indexed-cache file lengths, pinned as a subset, and bounded configured-sync-root file-length observations. Neither disk presence nor file length claims journal/revision equality. No combined physical total. | `storage_usage_page_test.dart`, `sync_disk_usage_test.dart`, `sync_disk_usage_page_test.dart` |
| Largest and oldest large files | Twenty largest files; twenty oldest files at least 10 MiB by namespace modification time, with unknown dates explicit. Not last access, verified content age or deletion advice. | `storage_usage_test.dart`, `storage_oldest_test.dart` |
| Exact duplicate candidates using local content hashes | Explicit review of already downloaded indexed revisions only. Local SHA-256 selects candidates; exact byte comparison confirms groups. Bounds/rejected copies mark coverage partial; results may become stale. No all-account or sync-folder content sweep. | `cache_duplicates_test.dart`, `cache_duplicates_page_test.dart` |
| Clear unpinned cache, review duplicates, open containing folder | Confirmed cache-only cleanup; read-only duplicate groups; largest/oldest rows open the freshly authenticated containing folder in the app. No duplicate deletion or automatic cleanup is added. | `cache_cleanup_measurement_test.dart`, `storage_cleanup_page_test.dart`, `storage_navigation_test.dart` |
| Totals match the listing/cache within documented tolerance | Zero bytes/files tolerance within the captured logical listing. Indexed cache uses observed regular-file lengths, not index estimates; sync scans label partial/unavailable observations. Mixed-time requests and excluded copies are disclosed. | Logical aggregation, cache measurement and real-filesystem sync observation fixtures above |
| Breakdown updates after upload/delete/sync | Acknowledged local namespace/content writes and completed sync coalesce session-owned snapshot refreshes; the dashboard adopts published revisions. Cache/sync-disk readings remain explicit entry/manual observations. | `account_mutation_refresh_test.dart`, `sync_mutation_refresh_test.dart`, `storage_usage_revision_test.dart`, `storage_usage_page_test.dart` |
| Cleanup confirmation and reported reclaimed space | Cancel/dismiss/late close admits no deletion. Current pins are checked serially; successfully removed regular-file lengths/counts are reported, with partial failures explicit. Lengths are not guaranteed free-volume growth or secure erasure. | `cache_cleanup_measurement_test.dart`, `storage_cleanup_page_test.dart` |
| No plaintext names or hashes sent to the backend | Authenticated names stay in session RAM; duplicate reads/hashes/comparisons stay local. No new plaintext wire fields, persistent name/hash index, telemetry or content uploads. | Real Session/native/loopback opaque-only requests in `storage_usage_native_test.dart`; local-only duplicate worker and queue tests |
| Large accounts without blocking the UI | Aggregation and content/scanner work run on top-level workers, with bounded winners/review IO/output and lifecycle drain. A 100k fixture proves totals/bounds; worker-location/event-turn tests prove dispatch, not installed frame time. | `storage_usage_test.dart`, `storage_oldest_test.dart`, duplicate/sync worker tests; installed performance stays #207 |

All test paths above are relative to `clients/flutter/test/`. Integrated PRs
are #206 and #208–#215. Their recorded canonical checks and regression/sabotage
runs remain in the issue/PR histories and [STATUS.md](STATUS.md).

## Fresh audit verification

The unchanged pinned wrapper reran these groups on the owned branch containing
v0.36.0:

```bash
bash scripts/dev-check.sh flutter-exec flutter test --no-pub \
  test/storage_usage_test.dart test/storage_oldest_test.dart \
  test/storage_usage_revision_test.dart test/storage_usage_native_test.dart \
  test/storage_navigation_test.dart test/cache_duplicates_test.dart \
  test/cache_duplicates_page_test.dart test/cache_cleanup_measurement_test.dart \
  test/storage_cleanup_page_test.dart test/account_mutation_refresh_test.dart \
  test/sync_mutation_refresh_test.dart
# 54 passing tests; wrapper exit 0.

bash scripts/dev-check.sh flutter-exec flutter test --no-pub \
  test/storage_usage_page_test.dart test/sync_disk_usage_test.dart \
  test/sync_disk_usage_page_test.dart
# 21 passing tests; wrapper exit 0.
```

These are targeted Linux container runs using the existing release native
library, not a newly built installed client or another full-suite run. This
audit changes documentation only; no implementation, guard, format or acceptance
criterion was modified.

## Deferred verification and explicit limits

[#207](https://github.com/ravand1990/nntdrive/issues/207) retains installed desktop/
Android inventory comparisons, cleanup and navigation/lifecycle checks, screen
reader/large-text reachability and measured large-account responsiveness. These
have **not** been run during this audit. They remain separate verification under
AGENTS.md §5, not evidence to describe as passing.

Earlier handoffs accumulated broader account/sync-folder duplicate review and
cleanup, other-device event subscriptions, continuation and persistent accounting
as remaining #84 work. The original scope did not require a complete remote
content sweep, duplicate deletion, continuous remote-event freshness or durable
accounting. The delivered bounded contracts above are not those broader features:

- [#216](https://github.com/ravand1990/nntdrive/issues/216) preserves explicit
  read-only sync-folder duplicate review as an unimplemented extension, starting
  in Backlog. It does not introduce or authorize another deletion path.
- Other-device/ambiguous-write freshness still requires entry/manual refresh or
  subsequent completed sync. Whole-tree traversal remains bounded and mixed-time;
  over-limit observations fail or are marked incomplete, never guessed complete.
- Persistent accounting, unlimited continuation, full remote-account duplicate
  finding and destructive duplicate cleanup are not implemented or promised by
  the bounded dashboard. Any such expansion needs its own explicit task/design.

This reconciliation removes stale claims that already-merged local mutation
freshness, folder actions, sync-root measurements or confirmed cache cleanup are
still missing. It does not turn installed tests, complete physical accounting,
content integrity or atomic snapshot guarantees into delivered capabilities.
