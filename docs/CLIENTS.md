# Client platforms

## Listing-scoped browser selection (#219 bounded slice)

**Select items** enters explicit selection mode in the current List/Grid view.
Rows and labelled 48 dp checkboxes toggle original opaque listing entries instead
of opening them. The live count stays visible; the adjacent action strip scrolls
horizontally on narrow/200% text layouts (keyboard focus also reveals controls).
**Select all visible** means all loaded entries matching the folder filter,
including offscreen lazy rows, not all account files. **Clear selection** stays
in mode; **Exit selection** restores ordinary row opening and item actions.
System Back closes docked Details first, then exits selection before going Up.
Exactly one selected item exposes the existing read-only **Selection details**;
there are no batch operations or placeholder mutation actions.

Selection and original model references live only in page RAM. Refresh (including
failure), navigation, close and disposal clear it; changing the folder filter
clears selections while retaining mode, so hidden entries are not selected.
List/Grid, sort and appearance changes preserve the current selection. Retained
selection callbacks reject old listing/navigation/mode/filter generations even
when transport reuses a model. No native select-all shortcut is intercepted:
text-field Ctrl/Cmd+A remains editing. Ctrl-click, Shift ranges, long-press entry,
selection shortcuts and batch writes remain future work. Existing guarded
single-item operations outside selection mode are unchanged. Synthetic 10k lazy
selection tests are not installed frame-time/latency or screen-reader acceptance
(#222); the parent redesign #219 remains incomplete. This section supersedes
earlier slice-specific statements that selection is entirely unimplemented.

For a dated, source-linked comparison with consumer cloud clients, see
[Cloud storage parity review](CLOUD-PARITY.md). That review separates integrated
features, remaining implementation gaps and installed-device acceptance.

## Adaptive browser navigation (#219 prerequisite)

The Files browser uses a 240 dp labelled sidebar at widths of at least 1200 dp;
Collapse navigation changes it to a 72 dp rail. Widths of 600–1199 dp use a rail
with a labelled destination menu. Below 600 dp, or above 130% text, use the direct
**Files / Search / Sync / Activity / More** bottom destinations. Files opens a
chooser for **Global** and **Devices**; it does not assume Global or navigate until
a location is chosen. More exposes **Trash**, **Settings** and **Manage devices**.
At very narrow widths or enlarged text, horizontally scroll the labelled strip
(the scrollbar and keyboard focus reveal the remaining destinations); full labels,
tooltips and at least 48 dp targets are retained rather than shrinking text.
Files is selected for Global/Devices, More for its other destinations, and direct
page destinations reflect only the supplied current selection. An unknown browser
location has no invented selection. The strip stays above the keyboard, consuming
the bottom keyboard inset once before the child Scaffold. The browser uses the
remaining window width instead of the readable-page 840 dp cap.

**Global** freshly lists and authenticates the account's Global root. **Devices**
returns to the existing account-root listing, including Global and device spaces;
it is not a device-only view. **Manage devices** separately opens the existing
device-session/revocation dialog. **Sync**, **Activity**, **Search** and **Trash**
open their existing pages; **Settings** opens the existing account/settings sheet.
App-bar adapters remain available. Child pages retain their normal Back routes
and do not yet embed this navigation. Resizing/collapse does not create a second
session or controller; collapse lasts only for this browser view.

The [adaptive client design brief](UI-UX-DESIGN.md) remains the broader contract.
Favorites/Recent projections, embedded child pages and
selection are unfinished; the bounded keyboard palette and read-only details
are described below.
Installed platform/accessibility/performance acceptance remains unverified.

### Appearance and browser density (#219 bounded Stage 2 slice)

Open **Account → Appearance** (also through **Settings**) and select **System**,
**Light** or **Dark** directly. System follows the OS brightness. Changes apply
immediately; Close, Back or the outside barrier dismisses the dialog without
undoing them. The existing integer `theme` preference remains compatible.

The same dialog offers **Comfortable** (default) and **Compact** browser density.
This nonsecret installation-local `browserDensity` preference survives app restart
and sign-out; it is not an account/remote setting. Missing or unknown values use
Comfortable. Compact reduces list vertical padding, narrow row padding and grid
gaps/tile height, not text size or global Material visual density. All item actions
retain 48 dp targets; grid columns/height continue adapting to text scale. The
dialog scrolls on short/narrow windows. Appearance rebuilds retain the browser
element/session/controller, folder, filter and List/Grid/order state; they do not
refresh/decrypt the listing. These automated layout/wiring checks are not installed
screen-reader, screenshot or performance acceptance (#222). Remaining Stage 2 and
all other unfinished #219 criteria stay open.

### List/grid and local ordering (#219 bounded browser slice)

Use **List** or **Grid**, **Sort: Name / Size / Modified**, and
**Ascending / Descending** above the current folder. Both surfaces lazily build
icon-based items, with the same open, More actions, favorite, offline-pin,
availability explanation and Show in folder adapters. No thumbnails or automatic
content downloads are added. Narrow/enlarged-text rows put actions below the name
and status; grid columns and tile height adapt to available width and text scale.
Controls retain labelled 48 dp targets. A filter with no matches offers Clear filter.

Ordering uses the listing's already locally decrypted display names, never a
server-side plaintext sort. Name comparison is case-insensitive, with exact name
then opaque ID resolving ties deterministically. Size means listed regular-file
bytes; directories sort as zero, not recursive totals. Modified means the listed
namespace modification instant, not last opened or verified content age. Unknown
or malformed timestamps sort last in both directions. Equal sizes/times use name
then ID ascending even when the primary direction is descending. The existing
case-insensitive folder filter preserves this order.

View/order choices live only in this browser view and survive folder navigation,
not process restart. Each successful refresh replaces the RAM projection; ordering
is cached until sort/direction or the listing changes, and filtered results are
reused until the query changes. Rebuilds perform no new HTTP, crypto, filesystem
inspection or content reads. Initial refresh/decryption and one-time sorting/filtering
still consume caller-isolate time and full-list RAM; lazy widgets do not make the
listing incremental or establish installed frame-time performance. Synthetic 10k
fixtures and real FilesPage wiring/layout tests are not installed-device acceptance.
The remaining #219 stages stay open; installed acceptance is tracked on #222.

### Loading, empty folders and listing errors (#219 bounded slice)

While an authenticated folder listing is pending, the browser shows static
placeholders using theme surface roles and a single **Loading folder** semantic
announcement. There is no shimmer, timer or animation, including with reduced
motion enabled. Placeholders are decorative, not file rows or selectable items.
An empty folder offers **Upload a file** and **Create folder**, delegating to the
existing file picker and guarded creation dialog. A filter with no results instead
explains **No matching files** and offers **Clear filter**, which clears the visible
field and local query without another listing request.

Listing failures show **Could not load this folder**, generic refresh guidance and
**Retry**; raw HTTP/native diagnostics are not displayed. Retry repeats the existing
authenticated listing workflow for the current location. HTTP 401 still requests
sign-out instead of Retry. Loading and error states replace prior rows: a retained
stale snapshot is not yet displayed. Errors never masquerade as an empty folder.
These scrollable states wrap their labelled actions with at least 48 dp targets;
light/dark, narrow 200% text, semantic loading and session-drain widget fixtures are
automated evidence, not installed screen-reader, file-picker or visual acceptance.
No protocol, crypto, selection, persistence or lifecycle ownership changes were
added. Stale-content retention and all other remaining #219 design criteria stay
open; installed accessibility/screenshots/performance acceptance remains #222.

### Read-only file details (#219 bounded slice)

Use the **Details for <name>** information button on a file or folder in either
List or Grid. At window widths of at least 1200 dp, Details docks in a 320 dp
read-only pane only when the actual post-navigation body leaves at least 480 dp
for the browser (plus a 1 dp divider). The browser stays interactive: another
Details button replaces the observation without opening/downloading the item.
The pane has scrollable metadata and an always-visible 48 dp Close control;
Close details, Escape or system Back dismiss it before parent navigation.
Smaller layouts retain the dismissible dialog capped at 560 dp, including its
Escape/Back/outside-barrier dismissal. Crossing the docking breakpoint dismisses
the current pane or dialog; it does not migrate or reopen stale observations.
Other resizes retain the observation. No selection model is added; existing row
open/More actions and density/theme choices are unchanged.

Both presentations reuse the current locally decrypted name and listing fields: type,
exact regular-file bytes, favorite and namespace modification time in UTC (Unknown
when absent). Listed size is not verified manifest content size, and folders show
**Not calculated**, never their metadata size as a recursive total. Namespace time
may include rename/favorite changes; it is neither last access nor verified content
age. Local/sync labels and explanations are frozen from the browser's existing
evidence with conflict/error/equality semantics unchanged. Unknown is not synced.
Pins refer only to observed device pin evidence for the listed revision, not a
content-integrity or durability guarantee; absent evidence explicitly includes an
unavailable cache. Folder pins are not applicable.

Opening details does not list HTTP, download/preview, inspect disk, hash, open a
journal/cache or invoke native inspection. Existing browser refresh/cache loading
is separate. Details is an explicitly possibly stale snapshot, not continuous
status: close and refresh to recheck. Browser refresh, destination/child navigation
and controller notifications, session close and disposal dismiss it; retained
callbacks from older refresh/navigation generations cannot reopen even reused
listing objects. No plaintext persistence, protocol, mutation,
permission or crypto changes were added. Automated layout/dismissal and production
wiring tests do not establish installed Windows/Linux/Android or screen-reader
acceptance (#222). #219 and all remaining stage criteria stay open.

### Browser commands and keyboard shortcuts (#219 bounded slice)

Use **Commands** above the listing, or **Ctrl/Cmd+K**, for a searchable, session-local
browser command palette. Type a label/binding, use Up/Down to change the highlighted
row and Enter to invoke it, or Tab to a row and activate it. Escape, Back, Close or
the outside barrier dismisses it. **Shortcut help** (also **Ctrl/Cmd+/**) lists the
same inventory and unfinished commands. Rows retain at least 48 dp targets; the
width-capped dialog scrolls, including its header/search on short windows.

| Binding | Available browser command |
|---|---|
| Ctrl/Cmd+K | Command palette |
| Ctrl/Cmd+/ | Shortcut help |
| Ctrl/Cmd+F | Account Search (not the folder filter) |
| Ctrl/Cmd+Shift+F | Focus the explicitly labelled current-folder filter |
| F5 | Existing folder Refresh |
| Alt+Up | Existing authenticated-path Up; disabled at browser root |

The palette also delegates Global/Devices, Sync, Activity, Trash and
Settings/account to the current production adapters. Devices retains the existing
account-root listing semantics. No new writer, backend endpoint, key handle,
selection model or plaintext persistence is introduced; Search/Refresh/navigation
keep their existing session ownership and guards. Direct browser shortcuts reject
text editing (including IME), modal/covered routes, loading/error/closed/disposed
pages and repeat admission. Refresh/navigation/controller changes or session close
invalidate an open palette; a result from an obsolete view cannot dispatch.
Successful selection and Escape restore browser focus (filter selection focuses
its field). A field's own select-all/delete/copy/paste behavior is not replaced.

Item open/rename/delete/move/copy/select-all/clear-selection/context-menu keys remain
**unfinished without selection**, not disabled promises of implemented actions.
Alt+Left/Right now follows listing history (below); Alt+Up is parent navigation,
not visit history. No destructive browser shortcut is registered. Ctrl and Cmd
variants are exercised in widget tests, not an installed macOS delivery claim.
Installed Windows/Linux/Android keyboard, screen-reader and performance acceptance
remain #222; the wider Stage 1/2/3 redesign remains open on #219.

### Breadcrumbs and listing history (#219 bounded slice)

The ancestry bar shows **Browser root** and the current folder trail. Select an
ancestor to visit it; the current crumb is disabled. Below 700 dp of breadcrumb
space, above 130% text, or beyond four folders, middle ancestors move into the
labelled **Ancestor folders** menu. Labels ellipsize with full tooltips, and menu
labels wrap. **Back/Forward in listing history**, Alt+Left/Right and the same
palette commands revisit successful browser locations, not application routes.
Up, Alt+Up and Android system Back retain parent traversal, creating ordinary
visits; at browser root Android Back can still leave the app.

History keeps at most 100 locations as opaque ancestor-ID lists in view RAM.
Refresh/reselecting the same location adds no duplicate; a new successful branch
truncates Forward. Global/Devices and search/dashboard browser destinations join
the same successful-listing history; child Sync/Activity/Search/Trash/settings
routes are not history entries. Filters clear on location changes; scroll,
selection, filter and view restoration per visit are not implemented. Close clears
history, decrypted labels/listing and the folder filter; nothing is persisted.

Folder open, Up, breadcrumbs and history re-list each expected ancestor from
root, require unique exact ID/parent/directory membership and locally authenticate
its fresh name before committing the trail. Missing/moved/duplicate/type-changed
or unreadable ancestry fails with generic refresh guidance, without advancing the
history cursor. Preliminary HTTP 401 keeps sign-out behavior. Final listing errors
retain the attempted trail with Retry, but do not record a successful visit until
refresh succeeds. Newer navigation/refresh/close invalidates pending results and
retained breadcrumb callbacks; admitted work remains in session drain.

This is sequential mixed-time validation, not an atomic namespace snapshot or
continuous rename/move freshness. Ordinary Refresh still lists the current folder
and retains previously authenticated ancestor labels until the next navigation.
Ancestry visits cost one listing per ancestor plus the normal listing/availability
refresh; full-list decryption and history RAM remain caller-side. Production widget
tests use real native sealed names, not a live backend or installed OS keyboard/
screen-reader/performance acceptance (#222). Remaining #219 stages stay open.

## Current state

| Platform | Source | Build status | Crypto/content |
|---|---|---|---|
| Windows 10/11 | Flutter + Rust FFI | ✅ release build verified, DLL bundled, app launches | ✅ works end-to-end |
| Linux desktop | Flutter + Rust FFI | ✅ release build and headless launch verified | ✅ works end-to-end |
| Android | Flutter + Rust FFI | ✅ release APK verified (arm64, armv7, x86_64 libs embedded) | ✅ works end-to-end |
| iOS | Flutter | Not built (no macOS/Xcode in this environment) | Rust static lib needs an XCFramework; File Provider still missing |

The 2026-11-05 NNT-016 container run passed `flutter analyze` and **12 Flutter
tests**, including tests that load the real Rust FFI library. This is a dated
snapshot before the six NNT-017 updater tests were added; the exact-head Clients
run [42130387280](https://github.com/ravand1990/nntdrive/actions/runs/42130387280)
passed all **18 Flutter tests** on the NNT-017 PR head that was subsequently
integrated. The historical
Linux/Android client smoke was exercised through the
exact Dart FFI layer against a running backend: register → create file → upload →
download → decrypt → byte-for-byte verify.

The shared Rust engine (`crates/ffi`, `crates/client`, `crates/sync`,
`crates/crypto`, `crates/storage`) does all cryptography and content handling.
Dart never implements crypto; it passes UTF-8 JSON to the native core.

## Mobile distribution policy

For now, sideloaded Android APKs and TestFlight-style iOS test installs are
accepted distribution paths; public store distribution is deferred. Android
users install the published release APK through the system package installer;
the Windows/Linux in-app updater does not install mobile updates.

This is a distribution policy, not an iOS delivery claim. The Android release
APK is currently debug-signed. iOS remains unbuilt/unverified, with no published
signed app or TestFlight delivery; a TestFlight-style install requires the iOS
build and Apple signing prerequisites tracked in
[NNT-007 / #12](https://github.com/ravand1990/nntdrive/issues/12).

The future Google Play Store / Apple App Store decision remains open until
signing and release ownership exist. No store launch date or production signing
is promised by this policy. Store publication, signing provisioning and mobile
update automation are outside
[NNT-014 / #19](https://github.com/ravand1990/nntdrive/issues/19).

## Implemented in the client

- Account creation (keyfile + recovery kit + Argon2 verifier) and login.
- Encrypted password unlock; recovery code shown once at registration.
- Browse folders, decrypt names locally, search/filter.
- Create folders, upload files, download + verify, version history with
  per-revision download and restore, delete, favorites.
- Keep a file offline in a bounded, evictable device cache with per-file pins
  and a cache screen that reports usage and clears unpinned copies (#82). The
  cache holds only downloaded copies, never sync folders or local-only files.
- Preview images and plain text/Markdown/CSV/JSON/YAML inside the app, using the
  pinned copy when there is one; unsupported or unreadable files explain
  themselves and offer the download fallback. Preview bytes stay on the device,
  the scratch copy is deleted before the preview renders, and image/text sizes
  are bounded (#83). PDF, audio/video and thumbnails are not implemented yet.
- Multi-folder bidirectional sync: select a base folder plus additional folders,
  automatic runs every 5 minutes while the app is open, pause/resume, per-folder
  and global “Sync now”, conflict copies preserved, selective sync per folder
  (excluded subtrees are ignored on both sides), conflict review panel, local
  plaintext by default.
- Device list/revocation, quota display, light/dark/system theme.
- Server URL + TLS backend support.

## Still missing in the client

- Virtual drive (FUSE/WinFsp), Android DocumentsProvider, iOS File Provider,
  photo backup, background transfers.
- Sharing UI/public links.
- iOS build/signing.
- Windows packaging/signing (build works; the FFI DLL must ship next to the exe).

<a id="account-wide-search-80-partial"></a>

## Account-wide search (#80)

Open **Search all files** (globe/search icon) in the file browser. Every opening
refreshes the account-wide index of decrypted names, including nested and empty
folders, independently of configured local sync roots; earlier results stay
visible while that build runs. **Rebuild account index** refreshes it again on
demand. A warm rebuild reuses names authenticated in
this unlocked session only for the same node ID and exact encrypted envelope;
new or changed names are opened again in bounded worker batches. Every folder is
still freshly listed and validated: metadata, moves, renamed ancestors and
removed entries replace the previous snapshot only after complete success.
A failed refresh keeps the previous complete snapshot, not partially updated
names, and shows an explicit "may be stale" warning that clears after a
successful retry. Any complete publication, including a rebuild started outside
the page, reruns the page's current query and filters once. This reduces repeated
decryption, not HTTP listing/parsing or tree assembly.
Name queries match case-insensitively, require
all space-separated terms and rank exact names before prefixes, word substrings
and other substrings. Up to 200 best results show their containing folder, size
and a refresh-time local/sync observation (or **Sync status unknown** when evidence
is unavailable). Selecting a result navigates through
the existing browser, refreshing before offering file actions. Offline searching
works on the existing snapshot; opening/refetching an item still needs the server.

Combine file/folder type, filename extension, minimum/maximum bytes, **Favorites**,
modification dates and status: **All statuses**, **Unknown**, **Local**, **Cloud only**,
**Not covered**, **Syncing**, **Conflict**, or **Error**. Status is observed during
the complete refresh, not continuously updated: sync, configuration and disk changes
can make it stale until the next refresh. **Local** means confined disk presence,
not journal/revision equality or successful sync. **Cloud only** requires a safely
mapped missing path; unknown/ambiguous mappings never match it. The loaded sync
configuration is copied for inspection; unavailable configuration leaves statuses
unknown. Exact-path active transfers and last-attempt errors retain the browser's
conflict/error precedence. No raw diagnostics or local paths enter search results.
Favorites come from actual namespace listings, not inferred
state. Dates use the server's namespace `updated_at` (including rename/favorite
changes), not authenticated content timestamps; **since** is inclusive and
**before** exclusive at UTC midnight (`YYYY-MM-DD`). Entries lacking dates do not
match date filters; directories do not match byte-size/extension filters.
Press **Search**/Enter to remember a search or **Save filter** to retain the full
combination; chips restore it. Each list retains at most ten session-local entries.

Names, paths, queries and saved filters live only in unlocked-session memory,
never the search network requests, preferences, index files, backups or logs.
Only normal ciphertext folder listings by opaque parent IDs are requested. The
index is closed/cleared before sign-out/Quit drains native work and locks keys;
late listing responses are rejected before decryption. Cold-build name opening
uses the existing authenticated native ABI on worker isolates, in sequential
batches of at most 128 names (one batch in flight). The whole listing/build,
including awaited worker completion, remains session-owned; close discards late
worker results and drain waits before key revocation. Worker errors are redacted.
A new session starts empty, and every search/build checks native unlock authority. Dart immutable
strings cannot promise physical memory zeroization; OS swap/crash dumps and
device compromise are outside this in-process guarantee. Existing intentionally
synced plaintext files/journals are separate from this index.

Status inspection reuses the filesystem confinement checks with authenticated RAM
ancestry and canonical collision validation for all siblings and ancestors; it
does not re-list HTTP folders per result. Inspection runs inside the owned build
before atomic publication, with cooperative yields and cancellation checks. Only
immutable scalar status enums reach query workers. Portable-name validation,
native NFC/lowercase/NFC comparison and sibling ambiguity grouping run in one
refresh-owned worker. It consumes sequential batches of at most 128 scalar
ID/parent/name records, keeping the growing counts private rather than repeatedly
copying them across isolates. The complete snapshot (at most 100k nodes) is
considered before returning safe IDs: late invalid siblings poison their entire
parent group, canonical aliases poison both spellings, and worker-side ancestry
walks reject descendants of either (see below). No native bridge object or cancellation
closure crosses isolates; the comparison ABI needs no unlocked-key handle.
Close stops further batches and rejects late evidence; the worker is finished and
awaited even on producer failure/cancellation before session drain completes.
Required config/path freezing, scalar batch assembly/transfers and final
candidate-map merging remain caller-side. Error/conflict-path indexing and
filesystem inspection run on refresh-owned workers. After grouping completes, another
refresh-owned worker retains the scalar snapshot and safe IDs once, then validates
and reverses ancestry for sequential requests of at most 128 entries. Each entry's
ancestry contains at most 257 nodes (the existing depth bound); cycles, missing/non-directory
parents and unsafe ancestors fail closed. It never materializes all full paths.
The caller awaits the refresh-owned filesystem worker's bounded inspection before
requesting the next ancestry batch.
Producer/consumer failure and cancellation finish and await the worker inside the
owned status build before session drain completes. Workers retain whole-snapshot
scalar/grouping state until completion; spawn/message/transfer costs remain. This
is not full cold-build isolation, an atomic filesystem snapshot or an
installed-device performance claim. A failed inspection preserves
the entire previous snapshot, including its possibly stale status observations.

Verified journal-equality result badges, durable encrypted offline
persistence/history and automatic event refresh are not implemented and are not
promised by #80's session-local search scope. Freshness is entry/rebuild-triggered
only: there is no polling, SSE
subscription or background re-listing, so edits made while the page stays open
appear only after a rebuild or the next opening, and offline snapshots may be
stale. Query scanning, combined filtering and bounded top-200 ranking now run in
one worker isolate at a time, returning only winning IDs. Exact ranking ties use
lowercased name then opaque ID. Superseded queued queries skip dispatch; late
results after a newer query, snapshot replacement or close are discarded. Entire
queued/running workflows remain session-owned until completion, including drain
before key revocation. A running scan is not forcibly killed. Each dispatched
query copies the bounded RAM snapshot to a short-lived worker; transfer/spawn
costs are not eliminated, and names remain in worker RAM until completion.
Cold name folding, entry construction and bounded entry-map assembly also run in
sequential worker batches of at most 128, including reused authenticated names.
Workers never receive the whole accumulated candidate. Builds await each worker
inside session ownership and reject late results after close before merging.
Search uses a dedicated listing API that collects at most **64 MiB (67,108,864
bytes) per folder response** before worker dispatch. Both advertised Content-Length
and actual streamed body bytes are checked; the latter are bytes delivered by the
HTTP client after any automatic decompression, not a wire-size guarantee. A
30-second header timeout and 30-second body inactivity timeout apply. UTF-8/JSON
decoding, the per-listing **100k model** check and `RemoteFile` construction run
in a top-level worker capturing bytes only, not the HTTP client/session/native
handle. Listings are sequential and parsing stays inside the session-owned build;
close discards late results while drain awaits completion before key revocation.
Malformed/oversized responses fail closed with redacted errors, preserving the
last complete snapshot. The byte cap is independent of the account's 100k-node
cap: unusually wide metadata can hit it with fewer nodes. There is no pagination
or partial-index fallback. Unrelated `listFiles` callers keep their old behavior.

Fresh traversal now validates each nonempty batch of at most 128 opaque models
on a top-level worker, passing only that batch, expected parent, current depth
and remaining account capacity. The worker checks parent membership, within-batch
duplicates, count/depth limits and discovers ordered node/directory IDs. Each
batch is awaited sequentially inside the session-owned build, including all-cached
refreshes; close/epoch is checked immediately afterward, before reuse/decryption.
Cross-batch/global duplicate checks still run on the caller before decryption,
without sending the accumulated snapshot to the worker. Discovered directories
enter the caller's queue only after the validated entry batch merges. Empty
listings still dispatch no batch, including an empty listing beyond depth 256.

Transport byte collection/concatenation, worker input copying, global membership
checks, reuse selection, queue updates and final candidate-map merges remain on
the UI isolate, with cooperative ~4 ms slice yields in traversal.
Worker spawn/send overhead and temporary decoded JSON/model memory remain; this
is not a fully off-isolate cold build or installed-device responsiveness
acceptance (#93).
Builds reject malformed/unreadable trees and bounds above 100k
entries/depth 256 without replacing the previous complete index. Synthetic warm
query tests are not installed-device/cold-network performance acceptance. No
content extraction or server-side plaintext search is introduced.

### Search acceptance and limits

The original #80 contract is implemented by the merged search increments through
PR #163. Earlier partial-work notes added durable persistence, continuous refresh
and total cold-build isolation as mandatory work; those are not criteria in the
issue body. This reconciliation does not claim those capabilities or remove the
requested responsiveness target. Under `AGENTS.md` §5, installed performance and
lifecycle verification remain the explicit Backlog follow-up #93.

All test paths below are relative to `clients/flutter/test/`.

| Original criterion | Implementation and repeatable evidence | Remaining verification |
|---|---|---|
| Matches across folders | Recursive root listing; `account_search_test.dart` nested/empty-folder ranking and `account_search_native_test.dart` native nested/offline fixture | Installed nested browsing in #93 |
| Combined filters and clear | `search_page.dart` controls and worker conjunctions; `search_page_test.dart` and `search_status_test.dart` combined, clear, saved/recent cases | Installed interaction in #93 |
| Path, size, status and opening | Result rows return the selected entry; `main.dart` re-lists before opening the current item; page rendering/selection tests | End-to-end installed browser actions in #93 |
| Offline indexed items; nonblocking cold build | Session RAM snapshot, failed-refresh retention, bounded workers/yields; search unit/native, listing and status-worker tests | Real cold-network/frame responsiveness in #93; not whole-build isolation |
| Account scope, clear on sign-out, no duplicate rebuild | Session-owned index, close-before-drain, duplicate/parent rejection and atomic publication; unit/native lifecycle tests | Installed delayed-listing sign-out/Quit in #93 |
| No plaintext leaves the device | Opaque-ID-only native/loopback request assertions, authenticated names, redacted errors and no search persistence | Installed preferences/cache/log inspection in #93; no physical RAM-zeroization guarantee |
| 100k entries and 10k p95 below ~150 ms | 100k bounded/yield regression and 10k synthetic warm-query timing test; 40 ms input debounce | Normal-desktop keystroke-to-painted-results p95 in #93, not established by worker timing |

On 2026-11-18, `bash scripts/dev-check.sh flutter` rebuilt the real release FFI,
reported clean analysis and passed **536 tests / four Windows skips**. The 20-query
synthetic warm 10k p95 was **22,952 microseconds**, excluding typing, paint and
installed-device costs. No code or tests changed for this documentation audit;
no new regression/sabotage claim is made. The search index and recent/saved
filters remain RAM-only and disappear across process/session restart. Optional
content extraction is not implemented.

## Storage usage (#84 first slice)

Open **Account → Storage usage** in the browser. The account menu scrolls on
small windows. The account report is read-only and shows:

- Exact logical live-file bytes/count from a complete account listing snapshot;
  zero-byte files count, directory metadata does not. History, trash, quota,
  encrypted/parity/physical Usenet bytes and local disk copies are not counted.
- Recursive usage for each top-level folder, including empty folders, plus a
  separate **Files at account root** group. Group identity is the opaque folder
  ID, not the decrypted spelling (same-named folders remain separate).
- Filename-extension groups, lowercased locally: the suffix from the last dot,
  except dotfiles without another dot and names ending in a dot, which join
  **No extension**. These are not MIME/content classifications.
- At most 20 largest files, ordered by descending logical size, then opaque ID
  for ties, with locally constructed account-relative containing paths. The
  breakdowns show at most 20 groups by bytes/name plus one exact **Other**
  remainder so the displayed group sums still match the full total.
- Up to 20 oldest large live files, with an inclusive **10 MiB (10485760 bytes)**
  threshold. Order is ascending `RemoteFile.updatedAt` instant, then size
  descending and opaque ID ascending. Output dates are UTC namespace modification
  dates, not last access or verified content age, and not a safe-delete
  recommendation. Missing/unparseable dates do not enter this list; the screen
  reports their count among large live files, including when no dated row exists.
  Directories are excluded regardless of their listed size/date.

Entry and **Refresh storage usage** freshly traverse the same authenticated RAM
index used by search; successful refresh replaces metadata/membership, including
changed sizes and removed files. While open, the page also automatically
reaggregates newly published complete index revisions without another HTTP
rebuild or cache/sync-folder measurement. History and busy notifications alone
admit no aggregation. At most one aggregate runs; revisions published while it
is suspended coalesce to the latest revision, and obsolete results/errors are
discarded. The page's own rebuild publication is consumed once, and a manual
refresh joins an already admitted aggregate before rebuilding.

There is no polling or SSE. A used session index refreshes after acknowledged
local account mutations and completed sync (see Local mutation freshness below);
other-device changes still need entry/manual refresh or subsequent sync. An already
published session snapshot can be displayed offline. A failed rebuild or current-revision aggregate
retains previous complete totals with stale guidance, never partial data or guessed
zero usage; a new successful observation clears the aggregation warning. A failed
unchanged revision is not retried on history/busy notifications. Close/disposal
rejects late publication and follow-up work, while session drain awaits admitted
workers. The manual refresh button is disabled until that refresh completes.
This metadata-only rebuild does not run search's optional local-status inspection;
the search page re-inspects on entry.

Tolerance is **zero bytes/files within the captured listing snapshot**. This is
not an atomic server transaction across folder requests: concurrent remote
mutations can make a successful traversal mixed-time, or make validation fail.
Listing sizes are server namespace metadata, not authenticated manifest content
sizes or a verified physical-space measurement; no content is downloaded or
hashed for this report. A malicious/rolled-back backend remains outside this
accounting guarantee. Negative sizes, overflow and malformed ancestry fail closed.

The pure aggregation, grouping/order and bounded winner-path construction run on
a top-level worker isolate; only sendable RAM metadata crosses it. Session
ownership awaits the full worker, rejects closed/locked/replaced observations and
drains before key revocation. There is no new backend endpoint, plaintext name,
path, hash or analytics request, and no new index/preferences/file persistence.
The screen releases its summary on disposal/close; admitted worker RAM can live
until completion. Dart strings cannot promise physical zeroization.

Input inherits search's **100k-node/depth-256**, per-listing **64 MiB**, bounded
name/parse/traversal worker contracts. The worker retains whole-snapshot grouping
maps and up to 20 winning entries per largest/oldest-large list before returning
bounded rows. Only winning paths and UTC date rows are constructed. Input map
freezing/copying and message transfer/spawn remain costs, as do search's HTTP
collection, global membership, queues and final merges. This is not an
incremental aggregation or proof of whole-build isolation, installed frame time
or a measured speedup. The 100k fixture establishes bounds/totals, not device
performance acceptance.

### Open containing folder (in app)

Both largest and oldest-large rows offer **Open containing folder**. This returns
to the encrypted file browser at the file's parent (or account root for root
files); it does not launch a device file manager, download content, open a file
action menu or modify account/cache data. Display paths are labels only. Rows
carry opaque node IDs, and navigation shares search-result resolution: every
ancestor and the selected entry are freshly listed by opaque parent ID and their
names authenticated locally before the browser refreshes the destination.
Renamed ancestors use fresh labels. Missing, moved, duplicate-ID, type-changed or
unreadable entries fail closed with generic refresh guidance, never raw network
or crypto diagnostics. This is a mixed-time traversal, not an atomic namespace
transaction; a concurrent move may require reopening/refreshing the report.

Replacement snapshots disable old report links until automatic reaggregation
successfully adopts the new revision. Failed offline
refreshes may retain links to the last complete snapshot, but opening still
requires fresh online listings and can fail safely. Selection and resolution are
session-owned: close/replacement rejects late results, admitted HTTP/decryption
is drained before key revocation, and disposed views do not navigate. The shared
search route still enters directory results and offers file actions only after
fresh browser listing; the dashboard route only opens the parent. Automated
widget/native HTTP coverage is not installed-platform acceptance (#207). The
[requirement audit](STORAGE-DASHBOARD-ACCEPTANCE.md) maps #84 to these delivered
bounded contracts; sync-folder duplicate review is a separate extension (#216).
Other-device event freshness is not implemented; bounded sync-folder file-length
observations are described below.

### Local mutation freshness

Once the authenticated search RAM index has a complete snapshot (or is building), session-bound
API acknowledgements invalidate it after create/bootstrap, rename/move, delete,
restore/purge/trash clear, favorites, version restore and rewind. Native browser
uploads/new versions and Copy notify only after successful publication. Completed
sync reports (including partial per-item failures) and successful conflict resolution
also invalidate once; byte-progress notifications do not. An unused index stays lazy.

One session-owned queue yields one event turn to combine bursts, joins an existing
manual build, then runs at most one traversal at a time. Changes during that traversal
request a coalesced follow-up, so they cannot disappear into an older build. Builds
reuse exact authenticated name envelopes and inspect current loaded sync evidence;
the dashboard adopts complete published revisions through its existing aggregation
queue. Failed builds keep the previous complete snapshot and stale warning, with no
automatic retry loop. Later mutations or entry/manual refresh can retry. Close stops
admission/follow-ups, rejects late publication and drains the queue plus admitted
HTTP/native/status workers before key revocation.

This is local acknowledgement-driven full-tree refresh, not polling, a server event
subscription, atomic account observation or incremental listing. Remote-device changes
still require entry/manual refresh or a subsequent completed local sync. Ambiguous
failed requests may already have committed and require manual refresh; a native sync
that throws without returning a report does not trigger refresh. Cache/pin and
sync-disk observations remain explicit/entry refreshes, separate from account bytes.
There are no new wire fields, name/hash uploads, plaintext persistence or dashboard
account writes. Full traversal cost and its existing bounds remain unchanged.

### Device cache measurement

A separate **This device · indexed offline cache** section reports total,
pinned and unpinned bytes/counts. These are actual regular-file lengths observed
on entry/manual refresh through `DownloadCache.measureUsage()`, not the cache
index's stored byte estimates. Counts represent cached revisions (including
zero-byte copies), not unique remote files; pinned copies are a subset of total
cache usage. No local bytes are added to the logical account total. The existing
cache is device-local, not an account-scoped inventory. Sync-folder data is
reported separately below, even if the same remote file also has a cached copy.

Measurement reuses the existing cache instance/index and serial operation queue,
with at most 5000 indexed entries. It performs asynchronous metadata probes only:
no recursive/broad directory scan, content read/hash, index rewrite, eviction,
reconciliation or call to `open()`. Scratch, orphan and index files are excluded;
this is neither whole-directory usage nor allocated disk blocks/device free
space. Missing/inaccessible/nonregular indexed paths are excluded with an
explicit count, without dropping their index rows. Actual size changes are
measured without claiming content/revision integrity. Missing/linked roots or
linked ancestors, corrupt recovered indexes, oversized indexes and failed
measurements are unavailable rather than a guessed zero. Linked cached entries
are not followed. Local external swaps remain non-atomic: pre/post type checks
cannot prevent hostile path replacement between metadata operations.

The browser supplies only its already opened cache (normally initialized by
listing/offline controls); the dashboard never opens it just to obtain numbers,
since opening can reconcile/delete scratch. If unavailable, retry after the
browser/offline cache becomes available. Cache and account refreshes run
independently: offline HTTP failures do not hide a successful local observation,
and a cache failure does not discard account totals. Failed cache refreshes keep
previous cache totals explicitly stale; successful retry clears that warning.
No observation is published after page disposal/session close. There is no new
logging, plaintext persistence or network payload, nor automatic invalidation.

Installed acceptance remains tracked by #207: compare on-device indexed file
lengths and revision counts with pinned/unpinned splits, change a pin/remove a
copy then explicitly refresh/reopen, verify offline account failures still permit
local readings and unavailable readings never look like zero; keep sync-folder
bytes and allocated/free device space separate. These automated fixtures do not
establish installed desktop/mobile filesystem behavior or hostile-swap atomicity.

### Confirmed unpinned-cache cleanup

**Clear unpinned cache** requires a separate confirmation explaining that only
this device's indexed unpinned downloaded copies are removed. Account files,
sync folders, pinned copies and unindexed scratch/orphan files stay untouched;
opening removed copies again needs the network. Displayed totals are not a
deletion plan: current pin flags are checked under the existing cache serial
queue when cleanup runs. No second deletion path or cache reopen is introduced.

The result reports actually deleted regular-file copies and lengths measured
immediately before deletion, not stored index sizes. Deleted empty files count;
already missing rows count as neither copies nor reclaimed bytes. Failed deletes
and unsafe nonregular replacements remain indexed for retry and are counted as
not removed. Cleanup refreshes measured totals even after a partial failure and
works with account listing offline. If index persistence fails after deletion,
the page reports possible partial cleanup, not a successful byte total. Failed
refreshes retain previous totals with an explicit stale warning; refresh must
succeed before retrying cleanup. Reports are historical, not live space readings.

Cancel/barrier dismissal, session closure or disposal before confirmation admits
no deletion. One dialog/cleanup is allowed at a time; refresh is disabled until
it finishes. Already admitted cleanup finishes under session drain even if the
page/session closes, but no late result/totals are shown. No keys or network
requests are needed by deletion. Regular-file lengths are not allocated blocks
or guaranteed newly available device space: hard links/open handles and external
changes can retain storage. No secure erasure or hostile path-swap atomicity is
claimed. Installed desktop/mobile cleanup acceptance is still unrun; #207 needs
confirmation/dismissal, pin preservation, measured result, failure/retry and
post-cleanup refresh checks alongside its measurement checks.

### Bounded sync-folder file-length observations

**This device · sync-folder file lengths** independently measures regular-file
lengths on entry/manual refresh. Each row identifies the configured root by its
position in sync settings, including disabled roots. Hidden, excluded, local-only
and conflict files are included: this is local disk evidence, not a remote
logical size, journal baseline comparison, verified synced bytes or cleanup plan.
No content/hash reads, journal open/migration, filesystem writes, permission
prompts, native sync calls or network requests are added by this measurement.

At most **20 roots** are admitted (more means unavailable), with a **shared
10000-entry / 2-second** cooperative scan budget. Output is at most 20 rows.
Directory enumeration streams one directory at a time without following links;
queued directories are bounded by visited entries. Every root/ancestor/component
is checked without following links and against its canonical path before
admission; regular files are rechecked after measuring length. Missing, linked,
non-directory or unreadable roots are unavailable. Links/nonregular children,
read failures, budget exhaustion and changed roots produce explicitly incomplete
or unavailable observations, never successful guessed totals. Incomplete rows
show only observed bytes/counts. The clock is checked between filesystem
operations: stalled OS operations can exceed two seconds. These are mixed-time
metadata observations, not hostile path-swap atomicity or content integrity.

Equal/ancestor/descendant configured roots are **both refused** as overlapping,
not silently counted twice or subtracted using partial readings. Adjacent roots
remain independent. There is deliberately **no combined local total**. Hard links,
sparse/compressed files, reflinks and separate cache/sync copies mean measured
lengths cannot establish deduplicated physical allocation or free-volume usage.
Nothing is added to cache/pinned or logical account totals.

All filesystem IO runs on a top-level worker receiving only bounded root paths.
Controller and session admission/drain own the full await; concurrent controller
refreshes coalesce, and close/configuration changes discard late observations.
Local measurement remains independent of offline account refresh. A failed
refresh retains the last observations with an explicit stale warning; close
clears them. There is no continuous filesystem watcher or mutation invalidation.
Installed desktop/mobile acceptance remains #207: compare known files, changes,
links, denied/missing and overlapping roots, partial budget output, offline
refresh and sign-out while measurement is pending. No installed acceptance is
claimed by Linux filesystem and widget fixtures.

### Explicit exact downloaded-cache review

**Review exact cache duplicates** is an explicit read-only action at the end of
Storage usage. Entry, ordinary refresh and search-index notifications do not
read duplicate content. It uses only the already opened cache's in-memory index
and existing serial queue; it never calls `open()`/reconciliation, walks cache
or sync directories, changes pins/LRU timestamps, writes an index, or cleans up
scratch/orphan copies. Cache mutations wait until the admitted worker finishes.
Controller plus session admission/drain own the complete await; closed sessions
and disposed views discard late results. Session-memory opaque file/revision IDs
label copies (and the frozen pin flag), not guessed authenticated filenames.

A separate top-level isolate checks canonical root/ancestors/components without
following links, accepts only regular indexed copies of the recorded size, hashes
contents with local SHA-256, then **byte-compares** hash/size candidates. Equal
hashes alone are not proof. Pre/post size/type/modification/change metadata checks
and final result revalidation reject observed changes. Empty files can form exact
groups. Missing, linked, nonregular, unreadable or changed copies are excluded,
without modifying their index rows. No new HTTP, telemetry, hash/content/name
persistence or logging is introduced; encrypted formats remain unchanged.

Production bounds are **1000 indexed revisions, 256 MiB of all content reads
(including both sides of byte comparison), 2 seconds cooperatively checked between
operations, 20 groups and 100 displayed copies**. Read buffers are at most 64 KiB;
input copying is bounded by the existing 5000-row cache index. Any scan/read/time
or display bound, or rejected copy, produces explicitly partial coverage. No
confirmed groups is not proof that no duplicates exist. OS calls may stall beyond
the clock bound; pre/post checks are not atomic protection against hostile local
path swaps or edits that evade filesystem metadata resolution. Results are
mixed-time, may already be stale, and require explicit rerun after changes.

This is **indexed downloaded revisions only**, not a complete account, revision
history or sync-folder scan, authenticated manifest/revision integrity, physical
storage accounting or safe-to-delete advice. There is no duplicate deletion action,
automatic removal, pin change, or reclaimed/free-space estimate. Existing explicit
unpinned-cache cleanup remains separate and does not consume duplicate groups.
Installed desktop/mobile review acceptance remains with #207: compare known exact,
different/empty and changed copies; verify partial/error output, pin/index/scratch
preservation, explicit-only admission, and close/disposal while review is pending.
Automated Linux filesystem and widget tests do not establish installed acceptance.

The bounded dashboard's original requirements and evidence are mapped in the
[#84 implementation audit](STORAGE-DASHBOARD-ACCEPTANCE.md); installed acceptance
remains #207. Broader sync-folder duplicate review is retained separately as #216.
Full remote-account duplicate sweeps/deletion, continuous other-device event
freshness, continuation and persistent accounting are not implemented by this
report. Bounds continue to produce incomplete observations, not complete inventories.

## What the Rust bridge exports

`crates/ffi` exposes a JSON C ABI:

1. `generate_account` — AMK/keyfile/recovery kit/verifier.
2. `derive_verifier`, `unlock`, `lock` — keys stay in a process-local handle table.
3. `seal_name` / `open_name` — encrypted filenames.
4. `upload` — stream chunk → compress → encrypt → POST ciphertext chunks → seal
   manifest → commit revision.
5. `download` — fetch sealed manifest → fetch/verify shards → Reed–Solomon
   reconstruct → decrypt → decompress → verify whole-file hash → atomic write.
6. `device_identity`, `recovery_kit`.

Dart (`lib/native.dart`) wraps this with `dart:ffi`; long calls run in an
isolate. The Flutter sync controller drives `crates/sync` through the
`nntdrive_sync_request` FFI call; older `sync_run`/`sync_run_ex` exports remain
compatible. Request callbacks carry owned JSON event strings, freed exactly once
with `nntdrive_string_free`. A terminal `finished` event is sent even on errors;
Dart waits for it before closing its receiving-isolate NativeCallable listener.
The blocking request runs in a worker isolate. Events stay device-local and
contain path, direction, logical bytes/total and commit/verification completion.
`tool/sync_smoke.dart` verifies two-folder progress and all conflict choices
against a real HTTP backend and mock NNTP fixture (see Development).

`nntdrive_sync_inspect(handle, request_json)` remains the legacy capped read-only
counterpart. The production "Not synced" overview uses the additive owned
`nntdrive_sync_overview_open`/`nntdrive_sync_overview_page` cursor instead (see
[bounded result loading](OVERVIEW-PAGING.md)). Both paths open an existing journal
without creating or locking it, scan the folder, walk the encrypted remote tree
and return the
plan a real sync would apply (`upload`, `download`, `create_local_dir`,
`create_remote_dir`, `delete_local`, `delete_remote`, `rename_local`,
`move_remote`, `adopt_revision`, `conflict`) with relative paths, sizes and the
skipped/case-collision lists. It uploads, downloads, deletes and writes nothing;
the HTTP transport may only refresh its own device-local content-hash cache.
A pending interrupted or identity-based folder move returns
`folder_moves_pending` and no items, because a plain comparison would misreport
it as a delete/download pair. A local root/scan I/O failure instead returns
`filesystem_blocked` (`permission_denied`, `not_found`, `not_a_directory` or
`io`) with empty item/skip/collision lists, before remote snapshot access or
reconciliation. Codes come from typed filesystem error kinds, never diagnostic
text, and contain no absolute paths or OS messages. The field is absent or null on
successful inspection; journal availability is not comparison evidence when
blocked. The overview counts one non-retryable **Blocked** root row, not an
invented count of unreadable descendants, and offers local access/drive guidance
plus the existing access action where supported. Journal, network, invalid
request and locked-handle errors remain errors and generic comparison notices,
not filesystem blocks. The controller rechecks the platform OS permission gate
before inspection, but leaves filesystem admission to the typed native inspector
instead of swallowing missing/file/unreadable roots in its listing preflight.
Denied or unavailable Android permission still prevents native admission; no
inspection requests broader access. Add-folder and ordinary sync retain their
full permission-and-listing preflight. Ordinary sync still aborts on scan failure
before reconciliation; this API does not change deletion behavior. The call runs off
the UI thread in a session-owned worker capturing only the handle and encoded
request. The cursor completes the full safe comparison before its first page,
then transfers at most 256 combined actions/skips/collision pairs per page.
Installed performance/permission/revocation acceptance remains separate (#65).

The production Dart overview maps, orders and projects each bounded page once on
workers, then appends immutable chunked all/status/folder/combined projections.
Counts and filters cover loaded mapped rows; partial publications are labelled
“loaded so far”, empty partial/error results never claim everything is in sync,
and all subsequent pages remain reachable without a 10k/20k cutoff. Status/folder
filters reuse prepared chunk lists without full-entry scans on rebuild. Only
within-batch ordering is applied; the growing result is not globally re-sorted.
Exclusions are emitted once in bounded batches after blocked/active precedence;
historical errors are indexed once and exact per-page endpoint matches preserve
current-conflict precedence. Native complete-set collision annotations keep
later collision pages from implying earlier action safety.

Legacy `buildUnsyncedOverview` retains its 20,000 default cap/global-sort contract.
The synchronous `UnsyncedOverview(...)` constructor remains for small hand-built
snapshots; production uses worker-prepared construction. Native comparison is
still whole-tree. Required report freezing/indexing, retained native/UI result
RAM, transfers, bounded endpoint selection, chunk-reference/group-map merges and
folder-summary/notice publication remain costs. Each row is referenced by up to
four filter projections. This is not a per-record byte bound, an installed
frame-time result or a whole-refresh speedup guarantee.

For a running folder, the Dart overview skips read-only inspection and shows one
non-retryable Pending observation: the exact path from a nonterminal upload or
download event, otherwise the folder root. It projects only scalar `path`,
`direction` and `complete`; byte totals and arbitrary diagnostics are not copied.
Terminal progress does not imply synchronized content. Initial activity for all
folders is frozen before the first await. Activity starting later is rechecked
before inspection, and the controller rechecks after permission/journal-path
awaits, returning a device-local `sync_running: true` marker instead of admitting
the native runner. This marker is not part of the native ABI. Permission checks
for idle inspection remain unchanged; running inspection never requests access.
Historical failures are suppressed for active folders. Counts and filters cover
only retained observations, never an inferred enumeration of active descendants;
the notice explains that full comparison awaits an idle refresh. An already
admitted native inspection is still awaited, not interrupted or mutually excluded
against later sync. No network mutation, journal format or key handling changes.

## Desktop window lifecycle (partial #6)

Windows/Linux close-to-tray keeps the **same unlocked process** syncing. Tray
menus expose Open, generic sync status, Pause/Resume and Quit. Hiding is not
locking the vault; use Sign out to lock and remove saved login settings, or Quit
to drain active work and exit (saved password-wrapped login is retained).

Linux needs `libayatana-appindicator3-1` at runtime and an active compatible
AppIndicator/StatusNotifier tray host. Builds need
`libayatana-appindicator3-dev`. Without a working tray host/icon, close quits
instead of hiding. Losing the host restores a hidden window. Relaunch normally
activates the existing window; an unavailable/busy settings lock never starts a
second sync session. Installed Windows/Linux tray and shell-restart acceptance
is still pending; a release build is not that evidence.

Windows/Linux login startup is opt-in on both the login and remembered-session
unlock screens (**Start NNTDrive when I sign in**), as well as the account menu.
It needs no account or password: changes immediately update the per-user OS login
item, then persist the choice after read-back. All views share the same state;
sign-out does not clear this install/user setting. Startup reads the current OS
item and re-registers a remembered opt-in for the current executable after updates.
Failures show inline Retry on login/unlock; unsupported platforms show a disabled
option with an explanation. The existing Linux XDG entry and Windows per-user Run
key mechanisms are unchanged. Installed login-session restart/registration removal
acceptance remains #171, including this pre-login entry point.

No cold-start automatic unlock or mobile background worker is registered.
A cold process still requires the password. See
[background sync](BACKGROUND-SYNC.md) for security boundaries and remaining work.

## Legacy reference preparation

After unlocking, open the account menu → **Prepare legacy references** →
**Start batch**. The client validates/decrypts manifests locally, including
historical and deleted-file revisions, then submits only opaque chunk IDs using
that session's bearer token. No keys or plaintext are sent to the server. Each
explicit batch processes at most 200 revisions within a 60-second deadline.
Results show confirmed revisions for that batch, remaining work, or a safe error;
**Continue / retry** restarts at the first incomplete revision. Confirmed writes
are immutable/idempotent, including retries after an ambiguous timeout. Counts
are acknowledgements, not a whole-account total. There are no automatic retries.
A bad manifest/wrong key stops the batch; resolve the cause rather than skipping
it. A clean pass does not enable GC or guarantee a concurrently uploading legacy
client cannot add incomplete history. Upgrade every client; admin GC independently
rechecks completeness. No NNTP articles or file versions are deleted.

`nntdrive_backfill_references(handle, request_json)` runs off the UI thread in a
separate top-level isolate helper and returns one owned JSON result, freed exactly
once with `nntdrive_string_free`; it retains no native callback/listener. Locked
handles fail before HTTP. Old cores missing this additive export fail safely;
ship Flutter and its native library together. Live browser acceptance is separate
and remains unperformed.


## Build instructions

### Linux and Android (all-in-one)

```bash
export ANDROID_SDK_ROOT=/opt/android-sdk
export NDK_HOME=$(ls -d "$ANDROID_SDK_ROOT"/ndk/* | sort -V | tail -1)
bash scripts/build-clients.sh
```

The script builds the Rust FFI core for Linux and all Android ABIs, runs
`flutter analyze` and the Dart tests (including the real FFI test), builds the
Linux release bundle and the Android release APK, and copies the Linux shared
library into the bundle. Artifacts:

- `clients/flutter/build/linux/x64/release/bundle/`
- `clients/flutter/build/app/outputs/flutter-apk/app-release.apk`

For development `flutter run -d linux` also needs
`clients/flutter/linux/lib/libnntdrive_ffi.so` (the script creates it).

### Windows

1. Enable **Settings → System → For developers → Developer Mode → On** (Flutter
   needs symlink support for plugin links; this requires an administrator).
   From an **administrator** PowerShell you can set the same policy directly:

   ```powershell
   reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
     /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1
   reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
     /v AllowDevelopmentWithoutDevLicense
   ```

   The last command must print `0x1`. Close and reopen the terminal afterwards.
   If the machine is domain-managed and the value reverts, ask IT to allow
   Developer Mode/`AllowDevelopmentWithoutDevLicense` (Intune/GPO); running the
   build from an elevated prompt is the fallback.

2. Install Flutter 3.47.9 for Windows and Visual Studio 2022 Build Tools with
   the C++ workload + Windows SDK. Add Flutter and Rust to the user PATH once so
   a fresh terminal can run both:

   ```powershell
   [Environment]::SetEnvironmentVariable(
     "Path",
     [Environment]::GetEnvironmentVariable("Path", "User") +
       ";C:\src\flutter\bin;$env:USERPROFILE\.cargo\bin",
     "User")
   ```

   Close and reopen the terminal. `flutter doctor` should show:
   `[√] Visual Studio - develop Windows apps` and a Windows 10/11 SDK. The
   Android toolchain warning on Windows is irrelevant when Android is built in
   WSL.

3. Build the Rust DLL (Rust MSVC toolchain):

   ```powershell
   cd C:\Users\you\Desktop\NNTDrive
   cargo build --release -p nntdrive-ffi
   copy target\release\nntdrive_ffi.dll clients\flutter\windows\runner\
   ```

4. Build and run:

   ```powershell
   cd clients\flutter
   flutter pub get
   flutter build windows --release
   .\build\windows\x64\runner\Release\nntdrive.exe
   ```

   Keep `nntdrive_ffi.dll` next to `nntdrive.exe` (the runner copies it in the
   current build; if not, copy it into the Release directory).

Developer Mode is not an SDK: it is the Windows policy that allows symlinks.
Without it Flutter stops with `Building with plugins requires symlink support`.

### Android

Use `scripts/build-clients.sh`, or manually:

```bash
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o clients/flutter/android/app/src/main/jniLibs build --release -p nntdrive-ffi
cd clients/flutter && flutter build apk --release
```

The jniLibs directory is generated (not committed). Without it the UI builds but
fails at runtime when it tries to load the native core.

### iOS

iOS requires macOS + Xcode and an `.xcframework` of the Rust core (a staticlib
build for `aarch64-apple-ios` plus simulator architectures). The current
`crates/ffi` can be compiled as a static library:

```bash
cargo build --release --target aarch64-apple-ios -p nntdrive-ffi
```

Then package the resulting `libnntdrive_ffi.a` with `xcodebuild -create-xcframework`.
This was not built or verified in this environment. File Provider, background
transfer and photo backup integrations remain separate work.

## Remaining native integration work

Android:

- **DocumentsProvider**: implement a `ContentProvider` subclass in Kotlin,
  declared in the manifest with `android:grantUriPermissions="true"`,
  `android:exported="true"`, and the `DocumentsProvider` intent filter. All file
  I/O must go through the Rust core; do not duplicate crypto in Kotlin.
- **Photo backup**: `MediaStore` queries + `WorkManager` with network and
  charging constraints. Android 13+ requires `READ_MEDIA_IMAGES/VIDEO`.
  `JobScheduler`/`WorkManager` are inexact; the OS may defer background sync.
- **Background**: use a foreground service with a persistent notification for
  long transfers; declare `FOREGROUND_SERVICE_DATA_SYNC` (Android 14+).

iOS platform constraints:

- **File Provider**: ship a File Provider extension target with an
  `NSFileProviderReplicatedExtension`. The extension has a small memory budget
  and must stream, not load whole files.
- **Background transfers**: `URLSession` background configuration works for
  downloads/uploads initiated before backgrounding; iOS may terminate the app.
  `BGTaskScheduler` grants short, opportunistic windows and is not guaranteed.
  There is **no** unrestricted background sync or arbitrary filesystem watching
  on iOS.
- **Photo backup**: PhotoKit, limited-library access, and user-granted
  permissions. Uploads must handle HEIC/HEVC and metadata.
- **Security**: keys go to the Keychain with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; never UserDefaults.

## Client updates

Windows and Linux clients check the latest GitHub release on every app launch
(including the login/unlock screen), ignoring the last check's 24-hour throttle.
They also check every 24 hours while open. **Account → Update settings → Check at
startup and daily** disables both automatic triggers; explicit **Account → Check
for updates** remains available. **Later** suppresses automatic prompts only for
that release version, not release checks or prompts for newer versions. Checks
and prompts are serialized across automatic and manual triggers, and offline or
inaccessible feeds never prevent using the app. The updater:

1. lists the repository's releases (paginated) and picks the newest stable one
   whose tag is a dotted version newer than the installed build; drafts,
   prereleases and non-version tags such as `nightly` are ignored;
2. collects the notes of **every** stable release between the installed version
   and that release, newest first, so a user who skipped several releases sees
   what changed in each; releases without notes are skipped, one section is
   shown per version, and the prompt stays scrollable under fixed section, body
   and total-text caps (dropped older sections are counted);
3. selects `nntdrive-<version>-windows-x64.zip` or
   `nntdrive-<version>-linux-x64.tar.gz` from the target release, falling back to
   the unversioned name used by older releases;
4. downloads over HTTPS and verifies the SHA-256 from `SHA256SUMS.txt`;
5. unpacks to a temporary directory and starts a detached helper;
6. exits, letting the helper replace the install directory and restart the app.

Release notes are read from the cached release list, not one request per version.
A dev build newer than every published release reports "up to date".

The helper launch is awaited before the app exits. Windows sends the script with
PowerShell's UTF-16LE `-EncodedCommand`, uses ordinary process creation with a
hidden window (not Dart's detached flags), and closes unused stdin immediately;
startup stderr is
retained in `helper-stderr.log`, and the app drains output without waiting for
helper termination. On Windows, the helper must
also acknowledge its archive-layout and directory-write preflight within 15
seconds; a launch/preflight failure leaves the app open with an error. It waits
at most 60 seconds for the old process to exit, then backs up overwritten payload
files, checks for locked/read-only targets, copies and hash-verifies the payload,
and starts the new executable. Existing files absent from the release (including
user data/journals) are not deleted. A replacement failure attempts rollback and
restart of the previous app and shows a Windows failure dialog; a rollback or
restart can itself fail, so this is not a durability guarantee.

Windows diagnostics remain in the system temporary directory under a unique
`nntdrive-update-handoff-*` directory: `update.log` names the failing step,
`failed`/`complete` records the outcome, `helper-pid` identifies the launched
helper, `update.ps1` retains its source,
and `backup/` retains overwritten files. Failed stages/backups are deliberately
not deleted. These files contain local install paths, not update tokens or keys;
review/redact paths before sharing a log. After confirming a working install,
these temporary directories and the matching staged update can be removed
manually. Installed-release version/data/journal preservation and locked-file
manual acceptance remain #49/#28; hosted helper fixtures do not replace them.
The Windows unit suite also compiles a disposable executable that launches the
production helper, exits while installed at the replacement
path, and requires a new process to write its own startup marker after replacement.
Run `flutter test test/update_handoff_test.dart --reporter expanded` with the
Flutter SDK (`FLUTTER_ROOT`) available. This checks helper survival, payload
replacement and a probe restart, not the packaged Flutter app, installed release
version or real user data. A `complete` helper marker alone means that Windows
accepted the launch request; it does not prove the app reached a usable window.

Public releases do not require a token. For a private release repository, open
**Account → Update settings**, set the repository and a read-only token; an
inaccessible private feed can return 404. The token is stored in the app's local
settings and used for release checks and asset downloads. Never reuse a coding
agent's GitHub write-capable PAT or automation credential for a client update
token. For public release assets, prefer unauthenticated downloads. Where
authentication is necessary, use a distinct, minimal, read-only credential with
the smallest practical scope and lifetime. Clearing the field removes it. **Test
access** verifies the repository and token before saving. Builds can still
provide a fallback with
`--dart-define=NNTDRIVE_UPDATE_TOKEN=...` and
`--dart-define=NNTDRIVE_UPDATE_REPO=owner/repo`. iOS is not updated by this
mechanism (it requires App Store/TestFlight or a signed enterprise install).

## Android in-app update check (#77 partial)

Android reads the same release feed but cannot update in place: the release APK
is downloaded, verified and handed to the Android package installer, where the
user confirms the upgrade. **Menu → Check for updates** runs the check on demand;
startup checks once per 24 hours and stays silent when offline. **Later**
remembers that version code only, so the next release prompts again.

Each release publishes `nntdrive-<version>-android.json` containing the APK's
version code, and the APK must appear in `SHA256SUMS.txt`. The client compares
version codes rather than display versions, and a release without the version
code, without a checksum entry, or with a mismatching download is refused before
the installer is opened. The staged package must stay inside the app cache and
its checksum is recomputed on the Android side before the installer session is
committed. Android 8 and newer need the per-app **Install unknown apps** switch;
when it is off the client explains it once and offers the settings screen instead
of looping. Nothing installs silently, and the app, its keys and the sync journal
stay in place. The current release APK is still debug-signed, so a real in-place
upgrade needs the stable signing key tracked in #77.

## Rename in the file browser (#51 partial)

### Recovering device-name onboarding (#144)

**Name this device** shows existing account spaces and root entries, decrypted
locally, and marks the entry whose name conflicts with your input. The initial
suggestion avoids existing canonical/case-equivalent names (for example
`Laptop (2)`). **Suggest an unused name** is available after editing or an error;
it does not silently replace an edited name. **Reload** refreshes the account
view without overwriting input or clearing a confirmation error. Choose a new
label and confirm again directly; no restart is needed to enter files/sync.

A definite guarded-rename 409 triggers one retry with freshly read root identity
and a complete newly decrypted sibling snapshot. A second rejection stays on the
page. Timeouts, disconnects, other HTTP errors and failed verification are not
automatically retried: their outcome may be ambiguous. Confirmation requires an
acknowledged write followed by opening the target's freshly listed sealed name.
The existing device root is reused; confirmation never bootstraps a root. Labels
and collision keys remain local, with only the existing opaque confirmation
boolean persisted. Global and legacy root entries also reserve their names.

### File and folder rename

Use the edit icon beside a file or folder to **Rename** it; Cancel leaves it
unchanged. Names are sealed by the native client for the existing node ID; only
`name_enc` changes via `POST /files/{id}/rename`, so contents and immutable revision history are retained.
The client refreshes siblings before renaming, decrypts their names locally and
rejects case-insensitive collisions, unreadable names, stale source entries and
non-portable path components. Device-name validation includes Windows `COM¹`,
`COM²`, `COM³` / `LPT¹`, `LPT²`, `LPT³` aliases and spaces before an extension
(for example `NUL .txt`). Malformed UTF-16 is rejected before network access, so
UTF-8 replacement cannot change the spelling between validation and encryption;
valid supplementary characters such as emoji are retained. These are portable
validation tests, not proof of installed Windows behavior.
Failures leave the dialog workflow recoverable
without displaying raw backend/native diagnostics. Sync still runs on its normal
schedule or via **Sync now**, not as a side effect of renaming.

This is a bounded implementation slice, not full #51 acceptance. Rename sends
its complete opaque sibling-name snapshot and parent ID. The backend compares
that snapshot and updates the name in one account-locked transaction; a changed
name, added/deleted sibling or moved source returns 409 and requires refresh and
a new local collision check. Successful rename emits a sync event. No plaintext
name, deterministic equality tag or new encryption format is introduced. Older
servers lack the dedicated endpoint: the client fails rather than falling back
to an unsafe PATCH. Guarded rename is bounded to 4096 sibling entries and a
2 MiB request body; larger folders fail closed. Namespace writes on this backend
(including legacy API routes) use the
same lock, but old backend replicas and direct database writers do not; upgrade
all replicas together. This is not server-enforced plaintext uniqueness: legacy
clients can still introduce duplicate names after the guarded rename.

Collision comparison uses Unicode NFC, Unicode lowercase, then NFC again in the
native client. Canonically equivalent spellings (including decomposed accents,
reordered combining marks and Hangul) collide, but the encrypted name retains
exactly the spelling entered. This is not compatibility normalization, full case
folding, confusable detection or a guarantee of every filesystem's equality
rules: for example `ß`/`ss`, `ς`/`σ` and `①`/`1` remain distinct. The comparison
value stays local and never becomes a server-visible equality tag. This requires
the matching bundled native library; a missing comparison symbol fails closed,
with no lowercase-only fallback. Sync scanner collision policy is unchanged.
Installed Windows/Linux plus two-device UI acceptance remain outstanding;
existing sync tests are not a substitute.

### Move in the file browser (#51 partial)

Use the row's **Move file / Move folder** action, browse decrypted destination
folders, and select **Move here** (or cancel). Root is selectable after navigating
up; the current parent is disabled and the source folder is never offered as a
destination. The backend rechecks descendant cycles even if the tree changes
while the picker is open. If a canonical name collision is found, rename the
source first or choose another destination; no entry is overwritten.

The client opens all destination names locally and sends only opaque IDs and
sealed envelopes to `POST /files/{id}/move-checked`. Under the same account
namespace lock as legacy writers, the server compares the complete destination
snapshot and source parent/name before updating the parent and publishing a move
event. The sealed name, node ID, size, current content revision, retained history
and child-parent relationships remain unchanged. No key sharing or re-encryption
is involved. Concurrent namespace changes return conflict and require fresh
preflight; there is no retry or unconditional-move fallback on older servers.
Bounds match guarded rename: 4096 destination siblings and a 2 MiB request body.
A content-only revision update need not invalidate a move. The server cannot
verify plaintext uniqueness; legacy clients and old replicas can still introduce
collisions later. Upgrade all replicas together. Installed OS and two-device UI
propagation acceptance remain unperformed.

### Copy in the file browser (#51 partial)

Use **Copy file / Copy folder**, choose another destination folder (Root is a valid choice),
then explicitly confirm **Copy**. The same name is retained; the current folder
is disabled. Collisions never overwrite an entry: cancel, rename the source or
choose a different folder. Folder Copy publishes the entire current subtree
atomically, including nested and empty folders. It excludes deleted entries and
old versions, leaves source history intact, and rejects destinations within the
source. It is bounded to 256 entries including the root, depth 31, 8 MiB candidate
metadata and 16384 references, with additional per-node/body/destination limits.
An oversized or unreadable tree fails without publishing a subset.

The matching `nntdrive_copy_file` native export runs the guarded SDK operation in
a top-level worker-isolate helper with one owned result, freed exactly once.
Keys stay in Rust. The source listing revision/name/parent and complete encrypted
destination namespace are checked atomically by the backend. Names/manifests are
resealed for fresh node/revision IDs; immutable v1 chunks retain same-account safe
dedupe, not independent content revocation. Source content/history is untouched.
Older cores/servers fail safely without a legacy fallback. Bounds and remaining
security assumptions are in [Copy design](COPY-DESIGN.md).

Only one attempt is admitted while the dialog is open, with no retry button.
After failure, **Copy was not confirmed** does not imply rollback: a lost response
may have committed. **Refresh** reloads the current browser; inspect the chosen
destination before initiating another copy. Never blindly retry with fresh IDs.
Errors omit native/server diagnostics and credentials. Copy-time renaming,
durable replay receipts and installed-client/two-device acceptance are deferred.
Native loopback HTTP tests are separate from widget-binding tests.

### Local presence and Show in folder (#51 partial)

Rows display **Local** only when the expected path exists under the configured
sync root with the correct file/directory type. **Cloud only** means that root
exists but the expected path is absent. **Not covered** explains missing sync
configuration or selective-sync exclusions; **Unknown** means mapping could not
be established safely (including unreadable or ambiguous sibling names).
**Error** indicates an inaccessible/missing root or unsafe/unexpected local path.
**Conflict** identifies an existing discovered conflict copy and its
same-directory original, even when the original leaf is missing, after checking
the copy is still a regular, non-linked file in a validated containing directory.
An absent original remains non-revealable; a missing ancestor cannot establish a
pair. This is a proposed pair, not journal-verified conflict resolution; review
revalidates hashes/revisions. Discovery is refreshed with the browser and after
sync (up to 500 copies per root). **Syncing** identifies only the exact relative
path of the covering root's active, nonterminal file-transfer event; unrelated
rows, directories and completed events retain their disk-derived labels. A
conflict label takes precedence over transfer activity. Local presence does not
prove journal/revision/content equality, even after a terminal transfer event;
folder transfer errors are not falsely attributed to every file in that folder.
Completed sync reports now include additive client-local `item_errors` records
with exact `paths`, an `operation` and a diagnostic-free error `code`. Action
failures identify all involved paths (both move endpoints/conflict candidates);
case collisions identify both spellings and missing-source folder moves both
endpoints. Legacy `errors` tuples remain unchanged. The browser marks only exact
paths from the last completed report as **Error**, never parses legacy diagnostic
labels, and never copies raw messages into the availability tooltip. Reports are
historical evidence of an attempted operation, not current revision equality;
while a folder is running, its previous report does not mark rows. Conflict
candidates retain precedence. Safe disk presence/reveal remains independently
available; excluded, ambiguous and unsafe mappings still fail closed. Folder-wide
exceptions and scan skips are not per-item failures. Missing originals without an
attributed failure are still labelled Cloud only.

For a present regular file in an idle root, refresh now checks its exact relative
path in the existing SQLite baseline, compares the listed remote content revision
and size, and freshly hashes the confined local file on a worker isolate. A
matching result adds an explicit **Local** tooltip confirming equality at that
refresh. No size/mtime hash cache or terminal progress event establishes equality.
Missing, legacy, corrupt or unreadable journals, pending moves, unknown revisions,
changed bytes and native failures retain the presence-only explanation; inspection
never creates, migrates or updates a journal. Directories remain presence-only,
not recursive subtree certificates. Conflict/error labels take precedence, and
starting sync suppresses the previous equality tooltip until a fresh idle check.
No names, hashes or journal paths are sent to the backend by this inspection.
Hashing reads the full file on each refresh and can take time for large folders.
This is a snapshot of observed local bytes and listed metadata, not an atomic
guarantee against hostile filesystem swaps, later edits, remote rollback or
provider retention loss. Bounded encrypted file/folder Copy is available as
described above; installed Windows/Linux and two-device UI acceptance remain
outstanding.

The sync core now persists the matching remote revision when both sides have
independently added or edited a regular file to identical known hashes and sizes.
Before updating SQLite it rechecks the local file's type, size and hash, rejects
symlinks, and requires a real revision in the remote snapshot. No upload/download
or transferred bytes are counted. Failed checks preserve the prior baseline for
retry; the resulting baseline survives restart and anchors subsequent edits.
This is a reconciliation fix, not a live browser integrity badge or protection
against a hostile concurrent filesystem writer racing the final journal write.

Refresh re-reads disk, and completion of all-folder or individual-folder sync
refreshes the browser. An initial refresh also runs after sync settings load.
Ancestry is re-listed and decrypted locally using opaque root IDs; stale cached
breadcrumb names are not used for filesystem lookup. Canonical-name ambiguity
fails closed. No names, comparison keys or local paths are sent to the backend.

Desktop **Show in folder** opens a file's containing directory; for a directory
it opens that directory itself (including a configured root, never its parent).
The action is disabled with an explanation without an inspected local path and
on mobile. Clicking re-lists remote ancestry and rechecks disk before launching
`explorer.exe`, `xdg-open` or macOS `open` with one argument, without a shell or
executing the selected file. Traversal, reserved/invalid components, symlinks
(including symlinked roots/ancestors), unexpected types and overlapping remote
root mappings are rejected. This is not a sandbox against a hostile concurrent
local writer: path validation and a separate OS file manager cannot be atomic,
and a filesystem swap after validation can still race the external application.
Installed Windows/Linux reveal and state-by-state manual acceptance have not
been performed; launcher fixtures do not establish OS integration acceptance.

## Navigation and back behaviour (#78 partial)

The file browser keeps one folder trail inside a single screen. Android system
back leaves exactly one folder and then, at the account root, lets the app close
as usual; the app-bar control does the same and is labelled **Up one folder**, so
the gesture and the visible control agree. Back never leaves a folder trail by
dropping the user out of the unlocked account.

Opening a folder keeps its name in the app-bar title, including ancestor folders
on the trail; a listing names only its own entries, so the trail keeps the names
it was opened under rather than showing a placeholder.

Text dialogs — rename and new folder — refuse to throw away typed input on back:
back asks **Discard your text?** with **Keep editing** and **Discard**, while an
untouched dialog closes silently. Cancel and the primary button are unchanged.

Not covered: predictive-back preview is not animated for the folder trail itself,
because Flutter disables the system preview for a route that cannot pop; the
gesture still goes up one folder. An unlocked session does not restore its folder
trail after process death — a cold start asks for the password again, which is
the intended behaviour for an encrypted client. Rotation keeps the current folder.
Installed-device acceptance of the gesture is covered by the manual pass tracked
on #78 and has not been performed.

## Folder sync walkthrough

Open the sync icon in the file browser, select a base folder (for example
`~/NNTDrive` or `C:\Users\you\NNTDrive`), and add any additional folders to mirror.
Use **Sync all now** or per-folder **Sync now**, or let the five-minute timer run
while the app stays open. Pause/resume and selective-subfolder exclusions are
available. Concurrent edits preserve conflict copies for explicit review.

The browser and sync share the same encrypted remote tree. Local synced files
remain plaintext on disk; use BitLocker, LUKS or FileVault for local disk
protection. Content and names sent to the backend/Usenet are encrypted locally.

## Android folder access (#69)

For shared storage, **Select base folder / Add another folder** opens Android's
directory picker, then explains the access scope before asking you to enable
**All files access** in this app's Android settings (Android 11+). Return to
NNTDrive to finish adding/syncing the folder. On Android 6–10 the app requests
read/write storage permission instead (legacy storage on Android 10). A granted
OS permission survives a normal app restart; the client rechecks it before every
sync, not a saved “granted” preference. Denial never initiates remote publication
or native sync. Canceling leaves existing folder configuration and journals intact.

This is deliberately broader than a SAF tree grant. The existing Rust sync engine
uses ordinary filesystem paths, directory traversal, hashing, atomic rename and
conflict-file recovery; it cannot operate on `content://` document streams. The
current directory-picker plugin returns an on-device path, not a persisted SAF
capability. A narrow SAF solution requires a new tree-I/O adapter throughout that
engine; converting a URI to a path does not grant POSIX access. For the current
sideloaded general folder-sync client we therefore explicitly request
`MANAGE_EXTERNAL_STORAGE`, **not** pretend a tree grant suffices. No media/contact
permissions are added. All-files access covers shared storage outside the chosen
folder too: only configured roots are synchronized, but this is an application
policy, not OS-enforced per-tree isolation. Public Play distribution would require
separate permission-policy review; this does not authorize store publication.

Alternatively, **Use app-private folder (no permission)** creates a sync directory
inside app storage. This is not a user-visible Documents folder: uninstalling the
app removes it. It does not need shared-storage access. Existing app-private or
already-authorized paths never open settings automatically. Protected system paths,
other apps' private data / `Android/data` and `Android/obb`, cloud document providers
and picker-unsupported storage volumes remain unsupported; a broad grant does not
bypass Android's restrictions.

If access is revoked, **Sync now** or the next automatic round shows a folder
error rather than successful empty synchronization. **Grant storage access and
retry** explains the scope, reopens settings only on explicit confirmation and
rescans the **same** configured folder after return. You may also restore access
in Android Settings and use **Sync now**, without deleting/re-adding the folder.

Refusals are classified before anything else happens. On Android 6–10 a
first refusal is retryable: the client keeps the folder, says access was not
granted and offers the app-private alternative, and only an explicit tap asks
again. A refusal the OS will not prompt about a second time — or any refusal on
Android 11+, where All files access only exists in system settings — is reported
as permanent and offers an **Open settings** action instead of a repeated
prompt; until access is granted, later attempts open app settings rather than
showing the rationale dialog again. Refusing never removes a folder, changes its
journal or reports a sync. The decision table itself is unit-tested on the JVM
(`StoragePermissionDecisionTest`), separately from installed-device acceptance.

Folder checks fail closed on unlistable directories; the native scanner aborts
the round on directory/metadata/file-read failures, including cached-hash reads,
so missing access is not interpreted as file deletion. Intentional exclusions and
skipped symlinks retain their existing behavior. Permissions can still disappear
during a later operation; that operation reports an error, not guaranteed success.

Names, paths and bytes remain local inputs to the existing encrypted sync engine;
permission checks send nothing to the backend. No plaintext upload or crypto
fallback is introduced. Focused channel/controller/widget and scanner regressions
are distinct from Android installed-app acceptance: fresh install/restart, actual
settings denial/revocation/regrant and shared-folder transfer on Android 11+ and a
current version still require the follow-up runtime verification.

## Sync model on clients

- One device-local SQLite journal (`nntdrive-sync`) holds the baseline.
- Scan on startup, on filesystem notifications (desktop), and periodically.
- `pause/resume` only pauses the scheduler; in-flight transfers complete or
  cancel safely.
- Conflict copies are preserved under `name (conflict device timestamp).ext`.
  Review shows both exact paths before offering Keep mine (preserved conflict
  version), Keep theirs (canonical version), or Keep both. Mine saves theirs as
  a synced `.recovered-<uuid>` file before replacing the canonical path; theirs
  archives mine under a synced `.recovered-<uuid>` name; both retains mine under
  `.kept-<uuid>` and theirs at the original path. No files/revisions are deleted.
  These names use UUID suffixes to avoid overwriting earlier recovery copies.
  Local hashes and fresh remote revisions must match the journal: sync first if
  review is stale, a prior operation was interrupted, or the baseline is missing.
  Legacy filename-based pairs are proposed visibly, not resolved automatically.
- Per-file progress measures actual logical plaintext bytes, including deduped
  chunks, rather than compressed/encrypted network bytes or estimated percentages.
  Full bytes with no completion flag means still verifying/committing; an error
  is not displayed as success. Empty files complete only after manifest commit.
- Selective sync is a per-folder exclusion list stored with the client config.
  Excluded folders are skipped while scanning local files and filtering the
  remote snapshot; they are not deleted on either side, and their sync history
  is kept so re-enabling them does not create conflicts.

## Environment limitations to document in the UI

- iOS cannot watch arbitrary directories; only its container and File Provider
  domains.
- Android shared-folder sync requires an explicit all-files grant for the current
  path-based engine; SAF tree selection alone is insufficient. App-private sync
  needs no shared-storage permission; protected paths remain unavailable.
- Windows drive letters need WinFsp service privileges; symlinks need developer
  mode/elevation.
- Linux FUSE mounts are per-user and may require `user_allow_other` for other
  applications.
- Background sync is best-effort on both mobile OSes. The app must tell the user
  when a sync is paused by the OS.

Android note: `AndroidManifest.xml` currently sets `usesCleartextTraffic="true"` so
the app can reach a local HTTP dev server (and the INTERNET permission is present
in release builds). Remove that flag and use HTTPS for any real deployment.
On a phone, `127.0.0.1` means the phone itself; enter the PC's LAN IP and allow
the port through the host firewall.
