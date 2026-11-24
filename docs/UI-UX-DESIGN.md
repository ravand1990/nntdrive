# Adaptive client design brief (#219)

Design prerequisite for [#219](https://github.com/ravand1990/nntdrive/issues/219),
checked **2026-11-24** against source at `5a328e6` and the first-party references
below. This is a proposed implementation contract, **not a shipped redesign**.
GitHub owns scope, priorities and stage completion; this document is not a
second backlog. The broader capability comparison remains [CLOUD-PARITY.md](CLOUD-PARITY.md).

## Evidence and method

Compare documented interaction patterns side by side, then choose patterns
compatible with self-hosted E2EE. Google evidence describes Drive **on the web**;
Microsoft evidence distinguishes the **website** from **Windows Files On-Demand**;
Apple evidence describes **Finder with iCloud Drive on Mac**, not Android or an
NNTDrive macOS delivery promise. Features differ by platform, plan and version.
No vendor account, installed client, screenshot comparison, usability study or
performance benchmark was run. The references support the patterns, not a
claim that NNTDrive matches their quality, speed or entire feature set.

Current NNTDrive observations come from `FilesPage` in
[`main.dart`](../clients/flutter/lib/main.dart),
[`app_layout.dart`](../clients/flutter/lib/app_layout.dart) and the existing
search, sync, activity, trash, preview and storage pages. The browser already
uses lazily built rows, local name decryption, per-file actions and availability
labels. It has an Up action and current-folder title, not breadcrumb/history
navigation. It places search/sync/refresh/trash/account in the app bar and more
pages/settings in account sheets. `AppContentFrame` caps content at 840 logical
pixels; increasing that cap alone would not produce a desktop file browser.
These are source observations, not an installed visual audit.

## Side-by-side pattern comparison

| Interaction | Google Drive web | OneDrive | iCloud Drive in Finder | NNTDrive decision |
|---|---|---|---|---|
| Navigation and context | Navigation panel, items view and details pane have explicit focus shortcuts [G1]. | Website left navigation exposes files and other views [M2]. | Sidebar locations include iCloud Drive; column view retains hierarchy [A1]. | Persistent destinations plus an opaque-ID breadcrumb/history model; do not emulate Finder column view in the first stage. |
| Views, ordering and inspection | List/grid switching, sort menu and details-pane toggles are documented [G1]. | Website list/compact-list/tiles, sorting and details pane [M2]. | Icon/list/column/gallery views, sorting and Preview pane [A1]. | Virtualized list/grid over one snapshot and one selection model; details on request. Start with icons, not invented thumbnails. |
| Selection and actions | Select-all, extend-selection, rename, move and context-menu shortcuts [G1]. | Website selection supports file actions; details show one selected item [M2]. | View/preview and contextual organization actions [A1]; keyboard selection specifics not assessed here. | Shared command model for toolbar, context menu, keyboard and palette; confirmations and guarded mutations remain authoritative. |
| Search | Combined type/date/people chips and name/content terms [G2]. | Website views/search are distinct from desktop file availability [M2]. Search ranking was not assessed. | Finder Smart Folders expose rules without moving files [A1]. Cloud search breadth not assessed here. | Reuse session-memory encrypted-name search and existing filters; distinguish account search from current-folder filter. No content/people search promise. |
| Local and transfer status | Exact offline/status semantics not assessed in this brief. | Online-only, locally available and always-kept copies have different icons; sync/error/paused states differ [M1]. | In iCloud, Downloaded, Keep Downloaded, Waiting to Upload and Out of Space differ [A2]. | Separate pin, confined disk presence, verified revision equality and transfer/error evidence. Unknown is never Cloud only. Text plus icon, never colour alone. |
| Preview | Preview keyboard commands are documented [G1]; format coverage is outside this comparison. | Website thumbnails/details [M2]; codec/format breadth not assessed here. | Preview pane and gallery reduce external opening [A1]. | Reuse current image/text previews. PDF/media/thumbnails remain #83; unsupported content retains explicit Download and open. |

### Adopt, adapt, reject

- **Adopt:** stable navigation, visible location, explicit view/sort controls,
  keyboard discoverability and contextual details. These reduce hidden actions
  without changing encryption or the backend API.
- **Adapt:** OneDrive/iCloud availability vocabulary to NNTDrive's actual
  evidence. A disk file, completed byte counter, pin or directory does not prove
  current remote-revision equality. Preserve current conflict/error precedence
  and freshness qualifications from [CLIENTS.md](CLIENTS.md).
- **Adapt:** Favorites and Recent as account/session-local projections, not new
  plaintext backend indexes. Favorites reuse existing opaque metadata; Recent
  initially means namespace modification ordering, **not last opened** or a
  complete cross-device activity history. Explain missing dates and snapshot age.
- **Reject:** server-side plaintext search, thumbnails, OCR, content previews,
  AI summaries and collaborative document editing. They are not shortcuts to
  this design and cannot cross the existing E2EE boundary.
- **Defer to their issues:** sharing/public links (#13), shell overlays (#86),
  native placeholders/providers (#14), PDF/media/thumbnails (#83). Do not put
  enabled dummy actions or misleading shared/placeholder badges in the shell.

## Information architecture and adaptive layout

Use one unlocked-session shell. Navigation changes must not construct a second
Session, SyncController, activity log, key handle or cache. Login, unlock and
required device-name confirmation stay outside it. App-wide update prompts
retain the navigator owner that survives onboarding replacement; tray/startup
preferences retain their install-scoped owner (#218).

Desktop destinations, in order: **Global, Devices, Favorites, Recent, Trash,
Sync, Activity, Search, Settings**. Global opens the authenticated Global root;
Devices exposes authenticated device roots plus separate device-management
actions. Sync includes folder controls and Not synced, not a new sync engine.
Settings groups Account/security, Appearance, Offline copies & cache, Storage
usage and Updates/startup. Storage retains separate logical/cache/sync-disk
accounting; moving its entry must not merge those totals or trigger cleanup.

Proposed breakpoints use **available logical content width**, not OS identity.
They require widget/layout evidence before being treated as final values:

| Width | Navigation | Browser and details |
|---|---|---|
| At least 1200 dp (including 1440) | 240 dp labelled sidebar, user-collapsible to a 72 dp rail | Flexible file area; optional 320 dp details pane only while the file area retains at least 480 dp. |
| 900–1199 dp (including 1024) | 72 dp rail by default; labelled destinations through an overlay | Full remaining file area; details in a dismissible overlay rather than squeezing the list. |
| 600–899 dp tablet/narrow desktop | Rail only if minimum content width and text scale allow; otherwise compact navigation | One content pane; details as sheet/route. |
| Below 600 dp phone/short landscape | Bottom destinations: Files, Search, Sync, Activity, More | Files contains Global/Devices/Favorites/Recent; More exposes Trash/Settings. All desktop destinations remain reachable, not nine cramped bottom tabs. |

At enlarged text scale prefer compact navigation earlier; never shrink labels or
hit targets to satisfy a breakpoint. Allow toolbar wrapping and scrollable
settings/dialog content. Preserve Android safe insets, keyboard padding, storage
permission flows and system Back. Long paths collapse middle breadcrumb items
into an accessible overflow menu; full labels remain available without forcing
horizontal overflow. Wide file surfaces replace the browser's 840 dp cap, not
readable login/dialog/settings constraints globally.

```text
Wide:   [Destinations] [Back Forward | Global > Folder | Search]
        [           ] [New/Upload | Sort | List/Grid | Details]
        [           ] [Selection actions, when selected       ]
        [           ] [Virtualized files         ][Details?  ]

Narrow: [Back | Folder title | Search | More]
        [Breadcrumb overflow / folder filter]
        [New/Upload | Sort | View]
        [Files or contextual selection toolbar]
        [Files | Search | Sync | Activity | More]
```

This is a structural wireframe, not a screenshot or golden acceptance.

### Navigation and selection contract

Keep history as destination plus opaque parent IDs, not decrypted path joins.
Up follows the current authenticated parent; Back/Forward follows visit history
and truncates forward history on a new branch. Re-list and authenticate before
navigation/actions; stale, moved or unreadable entries fail with refresh
instructions. Reuse search/dashboard navigation validation instead of resolving
an action from a displayed filename. History and decrypted labels clear at
session close. Nonsecret view/density/collapse preferences may persist, never
plaintext history, queries or selected names.

Selection uses opaque node IDs scoped to the current listing generation. An
ordinary pointer activation keeps current open behavior; checkboxes, Ctrl-click
and long press enter selection, Shift extends the visible ordered range. Clear
selection on parent change; after refresh retain only IDs still present and
revalidate revision/guard evidence before mutation. Select-all means the loaded
filtered folder view, not the whole account. Say how many are selected and
whether the listing is incomplete. Never silently execute a multi-item action
against hidden selections or imply a sequence of guarded single-item writes is
an atomic bulk operation. Report partial/ambiguous outcomes without blind retry.

Inline rename is a presentation of the existing guarded rename, not a second
writer. Escape cancels; Enter attempts once; preserve input on definite rejection.
Do not intercept text-field editing keys with browser shortcuts. Internal drag
move and external OS file-drop upload are distinct admissions: show destination
and intent, validate before publication and preserve normal collision/version
rules. Internal drag payloads carry opaque IDs in process, not decrypted names
through an external dragboard. External upload paths remain local; neither kind
bypasses confirmation, session drain, filename validation or account scoping.

## Shared components and ownership

Names below describe proposed responsibilities, not exports already present.
Keep extraction incremental; preserve existing pages as adapters until replaced.

| Proposed component | Responsibility and existing boundary |
|---|---|
| AdaptiveSessionShell | Navigation chrome and active destination; receives the existing session/controller. App lifecycle and onboarding ownership stay in `main.dart`. |
| DestinationModel / BrowserLocation | Stable destination and opaque history identity; session-only names. Reuse `account_roots.dart` identity rules and existing navigation validation. |
| BrowserToolbar / BreadcrumbBar | Location, folder filter, sort, view, New/Upload; wraps rather than hides primary actions at 200% text. |
| BrowserSelection / FileCommandRegistry | One enablement/confirmation path across selection toolbar, keyboard, context menu and palette; delegates to existing guarded operations. |
| FileListRow / FileGridTile | Lazy rendering, opaque keyed identity, name/type/size/date and status semantics; no per-rebuild decryption, hashing or network requests. |
| FileDetailsPanel | Display existing metadata/evidence, preview and explicit actions; no automatic download merely from selecting a row. |
| StatusPresentation | Preserve `local_availability.dart` semantics, conflict precedence, pin/revision distinctions and stale explanations; no generic green Synced from missing evidence. |
| LoadingSkeleton / EmptyState / RetryState | Stable reading order and shared next-action/error guidance. Keep previous successful content visible during refresh where safe. |
| AppTokens / AdaptiveDialog | `ColorScheme`/`TextTheme`, spacing, focus and density roles; reuse `app_layout.dart` insets and readable non-browser widths. |

Use spacing roles based on 4/8/12/16/24/32 dp and colour-scheme surface,
on-surface, primary, outline and error roles, not literal per-screen colours.
Comfortable and compact density may change spacing/columns but **not reduce
interactive targets below 48 dp**. Keep normal text contrast at least 4.5:1,
large text and meaningful nontext/focus indicators at least 3:1 against adjacent
colours; test actual theme pairs. Provide a visible focus indicator, icon-only
tooltips/semantic labels, selected/count announcements and keyboard traversal.
Reduced-motion settings disable shimmer/repetitive transitions; skeletons have
one loading announcement rather than individually focusable fake rows.

Empty folder: explain Create folder or Upload. Empty filter: Clear filter.
Unknown/offline listing: explain what could not refresh and retain a clearly
stale snapshot if one exists; never render an error as an empty folder. Unsupported
preview: explain format/limit and offer Download and open. Error messages must
be actionable and redacted, never raw diagnostics, keys or provider responses.

### Proposed keyboard map

Expose shortcuts in the command palette and menu labels; these are **not
implemented shortcuts**. Use `Actions`/`Shortcuts` with focus-scoped enablement.

| Intent | Desktop binding | Safety/availability |
|---|---|---|
| Open / rename | Enter / F2 | Exactly one valid item; rename keeps guarded preflight. |
| Delete | Delete | Existing logical-delete confirmation; never permanent purge by shortcut. |
| Move / Copy | Ctrl+Shift+M / Ctrl+Shift+C | Destination picker; Copy is an explicit operation, not plaintext clipboard export. |
| Select all / clear | Ctrl+A / Escape | Focused file view only; Escape closes transient UI before clearing selection. |
| Search / refresh | Ctrl+F / F5 | Search opens account search; folder filtering stays explicitly labelled. |
| Commands / shortcut help | Ctrl+K / Ctrl+/ | Same command registry and disabled reasons as visible controls. |
| History / parent | Alt+Left, Alt+Right / Alt+Up | Back/Forward versus authenticated parent; no path-string resolution. |
| Context menu | Shift+F10 | Focused item/selection; same actions as pointer menu. |

Respect IME composition, dialogs and editable fields; do not hijack native
copy/paste/select-all while typing. Future macOS bindings are not a delivery
claim; Windows/Linux and attached Android keyboards need actual validation.

## Delivery and verification boundaries

This brief satisfies only the documented-comparison/design/component prerequisite.
The first **runtime** slice should extract the session shell and location model,
wire existing Global/Devices/Sync/Activity/Search/Trash/settings entry points and
prove navigation/lifetime behavior before layering browser interactions. Favorites
and Recent need their real bounded projections, not placeholder destinations.
The Stage 1 browser/keyboard/details work, Stage 2 screen/token redesign and Stage
3 mobile/accessibility acceptance remain on #219. Do not declare a stage complete
from this document or silently remove any original criterion.

| Issue criterion / risk | Required evidence for the implementing slice (not run here) |
|---|---|
| Adaptive shell and breadcrumbs | Widget/golden fixtures at 1024, 1440, tablet and phone widths; collapse, path overflow, Up/Back/Forward, session identity and restored focus. |
| List/grid/sort/multi-select/context/rename/drop/details | Widget/model tests over real command adapters; exact selected IDs, stale refresh, collision rejection, cancelled/ambiguous operations and partial bulk results. Test drop upload and internal move separately. |
| Keyboard and discoverability | Keyboard-only tests and in-app shortcut/palette inventory; editable-field/IME exclusions, focus traversal and disabled reasons. |
| Android navigation and permissions | System-back, keyboard inset, narrow/tablet/landscape and interrupted permission-return fixtures; retain #78/#69 contracts. Installed TalkBack remains #129. |
| Tokens and accessible states | Light/dark/system screenshots, 200% text/short keyboard-open window, all targets at least 48 dp, semantic labels, contrast/focus checks and reduced-motion fixtures. |
| Large folder | Deterministic 10k-entry lazy-build/selection regressions, no decryption/hash/network in rebuilds; separately record installed frame-time and keyboard latency measurements with device/build/data, not a synthetic smoothness claim. |
| E2EE and lifecycle | Real Session/native/loopback fixtures for opaque-only HTTP, unchanged crypto and guarded mutations; suspended navigation/mutation and close/drain tests. Widget HTTP overrides cannot establish network evidence. |
| Screenshots and walkthrough | Before/after captures from actual Windows/Linux/Android builds with synthetic non-sensitive names; record environment, revision and usability steps. Vendor documentation is not these captures. |
| Documentation and acceptance | Update CHANGELOG, STATUS and client usage as each behavior ships; retain unverified installed work as explicit linked follow-ups under AGENTS.md §5. |

A design-only change needs local Markdown/reference checks and reviewed diff;
there is no runtime regression to sabotage. Each implementing slice must prove
its new tests catch missing wiring/old behavior, then run the pinned canonical
checks (`bash scripts/dev-check.sh flutter`, focused Rust checks if native code
changes) and inspect exact-head CI. Installed/performance checks are recorded
honestly, not invented or used to hold ordinary safe implementation indefinitely.
No deployment, crypto format migration, permission change or release is authorized
by this brief. A shell extraction should remain revertible without changing stored
data, key handles, preferences or the wire protocol.

## First-party references (read 2026-11-24)

- G1: [Google Drive web keyboard/navigation, selection, views and action shortcuts](https://support.google.com/drive/answer/2563044?hl=en).
- G2: [Google Drive search and combined filters](https://support.google.com/drive/answer/2375114?hl=en).
- M1: [OneDrive icons: availability, pinning, pause and error distinctions](https://support.microsoft.com/en-us/onedrive/what-do-the-onedrive-icons-mean).
- M2: [OneDrive website views, navigation, sorting and details](https://support.microsoft.com/en-us/onedrive/change-views-on-the-onedrive-website).
- A1: [Finder sidebar, views, sorting and Preview pane](https://support.apple.com/guide/mac-help/organize-your-files-in-the-finder-mchle9f0a1b2/mac).
- A2: [iCloud Drive status in Finder](https://support.apple.com/guide/mac-help/check-icloud-drive-file-folder-status-mac-mchlc994344b/mac).
