# Changelog

All notable changes are documented here. Every release tag **must** have an
entry with `### Features` and/or `### Bug fixes` (at least one bullet). The
release workflow refuses to publish if the entry is missing.

## [Unreleased]

### Features

- The offline cache limit is now a device setting instead of a fixed 2 GiB constant. **Change the cache limit** on the **Offline copies & cache** screen offers 256 MiB, 512 MiB, 1 GiB, 2 GiB and 5 GiB, or a typed size from 16 MiB to 1 TiB; the new limit applies at once — unpinned copies are evicted down to it, while anything kept offline is never deleted and is reported instead — and it is remembered for the next start on that device. The same screen now shows how much room the device really has left, read from the operating system through the native core (`statfs`/`GetDiskFreeSpaceEx`), and warns when the device has less free space than the limit or when kept-offline copies are larger than it (#199).
- Files can be previewed inside the app: **Preview here** in the item menu renders images in a zoomable viewer and shows plain text, Markdown, CSV, JSON and YAML as selectable text, using the pinned offline copy when there is one so a kept file previews without the network. Anything else, or an unreadable file, explains itself and offers **Download and open**. Decrypted preview bytes never leave the device: the revision is read into a short-lived scratch file that is deleted before the preview appears, leftovers from an interrupted run are purged on first use, and images/text are capped (32 MiB / 512 KiB, first 200,000 characters) so a large file cannot stall the page. PDF, audio/video, thumbnails and lazy page rendering remain open in #83 (#83).
- Files can now be kept on this device: **Keep offline** downloads the current revision into a bounded device cache and pins it, the browser marks the row, and the same action removes the copy again. A new **Offline copies & cache** screen reports how much of the cache limit is used, how much is pinned, how much headroom is left and which revisions are cached, and can clear every unpinned copy while reporting the entries and bytes it reclaimed. Only the client's own cache directory is involved: sync folders, local-only files and saved copies are never candidates, pinned copies are never evicted, and an interrupted download leaves only a scratch file that the next open discards (#82).
- The released container image is now a multi-architecture manifest: the release workflow builds the backend natively on GitHub's amd64 and arm64 runners, merges both digests into one manifest, refuses to publish unless both platforms are present, and says so in the release notes. Ordinary CI builds both architectures before merge, so an arm64-only breakage fails on the pull request instead of at release time (#18).

## [0.34.0] - 2026-11-21

### Bug fixes

- In the **Not synced** list every row is now announced as one screen-reader item — name, status, reason and folder in that order — instead of three fragments in layout order, so the status and reason are no longer heard apart from the file they describe. The retry button stays a separate control, status is still shown as text plus icon rather than colour alone, and nothing new leaves the device (#79).

### Features

- A failure or conflict in the activity feed now leads straight to its folder: every such row, in the notification centre and in the feed, has a "Show in Not synced" action that opens the Not synced list for that sync folder only. Dismissing the notification leaves the action on the underlying row, so dismissing never hides the way to the error, and a folder that was removed in the meantime is reported instead of opening an empty list (#87).
- The **Not synced** list now also shows the comparison step of a running sync: while the engine lists the remote copy, the paths it has already compared appear as Pending "Comparing with the remote copy." rows, so a large folder no longer falls back to one opaque "Sync is running." row between the scan and the plan. The transport reports bounded batches of at most 64 decrypted paths (at most 4096 per run), the client keeps the first 256 and still counts every reported path, selective-sync exclusions are never reported, and queued plan rows replace them as soon as reconciliation starts (#79).
- The **Not synced** list now shows what a running sync is doing while it scans: the local paths the device has already examined appear as Pending rows instead of one opaque "Sync is running." row. The native scan reports bounded batches of at most 64 paths each (at most 4096 per run), the client keeps the first 256 and still counts every reported path, and queued plan rows replace the scan rows as soon as reconciliation starts (#79).
- Revoking a device now offers to rotate the account key in the app instead of leaving the revoked device able to read everything stored before the revoke. The prompt asks for the account password (transiently, never stored); an account with a recovery kit also asks for its current recovery code, shows the replacement code once and copies it on request. The rotation itself runs in the native core: it refuses a password that does not open the stored keyfile and a keyfile that no longer matches the unlocked session, publishes the new keyfile together with the replacement kit, and keeps the live session working on the rotated key so earlier revisions stay readable (#184).
- Rotating the account key now replaces the recovery kit instead of leaving a stale one behind. Rotating an account that stores a kit requires its recovery code and mints a fresh kit for the new epoch that keeps every earlier epoch; the keyfile and the kit are published in one request, and the backend refuses a publish that would leave the stored kit behind the keyfile. A kit minted after a rotation still restores revisions sealed before it, a kit minted before a rotation is reported as stale with an actionable message instead of an unexplained decrypt failure, and `recovery-restore` restores every epoch the kit covers. Older kits without the new field keep working unchanged (#185).
- Unlocking now keeps every retained account-key epoch in the native handle: names, manifests and chunks sealed before another device rotated the account key stay readable, while new content still seals with the current epoch. The desktop and Android client also fetch the published keyfile at unlock and adopt it only when it is newer for the same account, falling back to the local copy when the fetch fails or the published copy cannot be opened; the installed two-device check is still to come (#184).
- The activity feed now names files instead of only counting them: every completed upload and download becomes its own local row with the file name, folder and size, while a run that moves many files keeps a bounded number of named rows and summarises the rest. Names, sizes and folders stay on the device; nothing new is sent to the backend, and a run whose transfer events were not observed still records its honest total (#87).
- Root key rotation after a device revocation: `KeyFile::rotate` creates a new AMK epoch and keeps every previous epoch wrapped inside the keyfile, `MasterKeyRing` reads names, manifests and chunks sealed under any retained epoch while new content always uses the current one, and `KeyFile::rewrap` re-wraps the whole ring on a password change. The backend stores and publishes a rotated keyfile through `GET`/`POST /api/v1/account/keyfile`, guarded by an expected epoch so two rotations cannot fork the account key. The client SDK exposes `fetch_keyfile` and `rotate_account_key`; a failed publish leaves the stored keyfile untouched, and an already applied publish is idempotent (#8).

## [0.33.0] - 2026-11-20

### Features

- The password-wrapped keyfile now lives in the operating-system credential store on Linux (Secret Service, the API behind GNOME Keyring, KWallet and KeePassXC) and Windows (Credential Manager) instead of shared preferences. Existing installs migrate once on the next start: the new copy is written and verified before the old one is removed, so an interrupted migration leaves a duplicate rather than a lost login. When no credential store is available or it is locked, the wrapped keyfile stays in shared preferences exactly as before and sign-in still works (#7).
- On Android the password-wrapped keyfile is now encrypted with a non-exportable Android Keystore key (AES-256-GCM) before it reaches a private preference file, and the client picks that store automatically; the same one-time migration and preferences fallback as on desktop apply. Keystore failures, including a missing or unreadable entry, keep sign-in working through the wrapped copy in preferences (#7).
- The activity feed has a local search field. Typing narrows the rows by local name, folder, kind or failure reason, ignoring case, and every word typed must appear in a row; search combines with the existing kind and folder filters. The query stays in memory: it is never stored, logged or sent to the backend (#87).
- The activity feed has local settings for how long this device keeps its history: 7, 30, 90 or 365 days (30 by default). Picking a shorter window drops older rows immediately, the choice is stored per account and restored on the next start, and cancelling leaves the window untouched. Files, sync folders and sync reports are not changed and nothing is sent to the backend (#87).

## [0.32.0] - 2026-11-20

### Features

- The client now keeps a device-local activity feed and notification centre for the signed-in account: uploads, downloads, copies, moves, renames and deletes made in the browser, plus one row set per finished sync run (uploaded/downloaded counts, conflicts, and a failure with a short reason). Failures and conflicts also raise a dismissible notification that never hides the underlying row. The feed is filtered by kind and folder, bounded to 500 rows and 30 days, stored per account, cleared on sign-out and never sent to the backend; the export report uses opaque ids unless local names are explicitly chosen (#87).

## [0.31.1] - 2026-11-20

### Bug fixes

- Adding a sync folder now has an end-to-end regression: a real local folder is selected through the client controller, synced through the native engine against a loopback backend, and checked for the remote folder, the encrypted chunk, the committed revision and the stored journal baseline. A future change that stops uploading, sends plaintext, or forgets the baseline row now fails CI instead of passing silently (#17).

## [0.31.0] - 2026-11-20

### Features

- The Not synced screen now lists every queued item of a running sync instead of one summary row per folder. Before the first action the sync engine reports its complete reconciliation plan in bounded batches, so uploads, downloads, folder work, moves, deletes and conflicts appear with their current phase ("Uploading this file.", "Waiting to download this file.") and a truncation notice when the plan exceeds the reported bound (#79).

## [0.30.3] - 2026-11-20

### Features

- `scripts/backup.sh` and `scripts/restore.sh` can target an existing PostgreSQL container with `PG_CONTAINER` (plus `PG_USER`, `PG_DB`, `PG_ADMIN_DB`) instead of the Compose stack, and refuse the ambiguous combination with `USE_LOCAL_PG=1`. A new `scripts/test-restore.py` runs in CI: it migrates and seeds a disposable database, backs it up, damages it, restores it, and verifies that the rows return and that an unconfirmed, missing or tampered restore is rejected before anything is dropped (#17).

### Bug fixes

- `checkpoint.json` now lists the migrations the repository actually ships instead of the fixed `0001_init.sql,0002_account_keys.sql` pair, which had been stale since migration 0003 (#17).

## [0.30.2] - 2026-11-19

### Bug fixes

- A version commit that is sent twice is now rejected with a clear `409` conflict instead of an opaque internal error. A client that loses the response to an acknowledged commit learns that its revision is already stored and can refresh, and the retry creates no second version, revision bump or sync event (#17).

## [0.30.1] - 2026-11-19

### Bug fixes

- An interrupted download no longer leaves a partial `.nntdrive-part` file next to the destination: the temporary file is removed when fetching, verification or materialization fails, so only complete, hash-verified content is ever materialized. Failed uploads keep no visible version and a retry reuses chunks that were already stored. Covered by new client end-to-end interruption tests (#17).

## [0.30.0] - 2026-11-19

### Features

- Desktop clients can opt into **Start when I sign in**. The account menu writes an XDG autostart entry on Linux or a per-user Run value on Windows for the running binary, removes it when switched off, and re-registers a remembered choice at launch so an updated or moved client keeps starting. Registration failures are reported in the menu and never flip the stored choice; the client still starts locked and needs its password. Installed login acceptance remains #66, and mobile scheduling is still unimplemented (#6).

## [0.29.0] - 2026-11-19

### Features

- Not synced now loads every result through bounded, session/controller-owned native pages rather than stopping at 10,000 actions per folder or 20,000 overview rows (#79). Complete safe comparison precedes pages; each batch is mapped/ordered/projected once and appended without re-sorting accumulated rows. The screen publishes loaded-only partial counts, automatically consumes later pages, and keeps folder/status filters and incomplete/error labels truthful. Legacy APIs, current collision/conflict precedence and cancellation/drain remain. This is result loading, not incremental filesystem scanning or an installed performance claim (#65).

## [0.28.10] - 2026-11-18

### Bug fixes

- Not synced shows one Pending active-sync observation per running folder: the exact nonterminal upload/download path when known, otherwise the root. It suppresses historical failures and redundant inspection, including sync starting during permission/journal admission. Counts cover retained observations, not all active descendants; full comparison awaits an idle refresh. Native inspection remains non-incremental (#79).

## [0.28.9] - 2026-11-18

### Bug fixes

- Closing the Not synced page cancels admission of later folder inspections and mapping/ordering/projection workers. An already running stage is still awaited; its late result or failure cannot start another stage or update the closed page. This does not interrupt a native scan already in progress or add incremental native inspection (#79).

## [0.28.8] - 2026-11-18

### Bug fixes

- Encrypted search applies the completed refresh's status map to entries on a device-local worker before atomic snapshot publication, rather than constructing every replacement entry on the UI isolate. Missing/unknown status semantics, authenticated names and metadata remain unchanged; failed refreshes retain the previous snapshot and session shutdown drains the admitted worker. Full-map message copies and earlier candidate merges remain costs; no whole-build isolation or measured speedup is claimed (#80).

## [0.28.7] - 2026-11-18

### Bug fixes

- Encrypted search inspects local availability on a refresh-owned device-local worker. Frozen scalar root evidence is transferred once; sequential ancestry batches contain at most 128 entries and return only IDs/status enums. Fresh no-follow component/canonical checks and conflict-copy probes retain existing confinement and precedence, with no filesystem acceptance cache. Cancellation and failures finish and await the worker before session drain. Required freezing, message copies and final merging remain caller-side costs; no whole-build isolation or measured speedup is claimed (#80).

## [0.28.6] - 2026-11-18

### Bug fixes

- Encrypted search prepares per-root exact conflict membership and same-directory original-to-copy candidate lookups once per refresh on an owned worker, using sequential batches of at most 128 paths. Empty prepared indexes never fall back to repeated discovery-list scans; browser consumers retain live discovery. Every actual candidate still receives fresh confined filesystem checks, with missing-ancestor and conflict/error/transfer semantics unchanged. Required freezing, message copying, filesystem inspection and final merging remain costs; no measured speedup or whole-build isolation is claimed (#80).

## [0.28.5] - 2026-11-18

### Bug fixes

- Encrypted search validates status ancestry and constructs root-first paths on one refresh-owned device-local worker. Snapshot scalar inputs and sequential requested outputs are bounded to 128 entries per batch, with at most 257 ancestors per entry; unsafe names, missing/non-directory parents, excessive depth and cycles still fail closed. Cancellation and producer/inspection failures finish and await the worker. Configuration copying, input assembly, filesystem IO and final merging remain caller-side; no measured speedup or whole-build isolation is claimed (#80).

## [0.28.4] - 2026-11-18

### Bug fixes

- Encrypted search builds per-root exact-path error indexes, including final immutable sets, on one refresh-owned device-local worker using sequential batches of at most 128 validated frozen paths. Cancellation and producer failures finish and await the worker before the build drains; all roots still freeze before the first await and browser error semantics remain unchanged. Required-field copying, ancestry/conflict/filesystem inspection and result merging remain separate caller-side costs; no whole-build isolation or measured speedup is claimed (#80).

## [0.28.3] - 2026-11-17

### Bug fixes

- Encrypted search freezes only availability configuration, progress path/completion, conflict paths and validated structured item-error paths before refresh inspection. It no longer JSON-copies entire sync reports or traverses unused nested diagnostics. Exact-path/root isolation, active-transfer/error/conflict precedence and all-roots-before-await snapshot semantics are unchanged. Required path copying and error-index construction remain caller-side costs (#80).

## [0.28.2] - 2026-11-17

### Bug fixes

- **Not synced** admits only one page refresh at a time. Sync notifications during inspection coalesce into one follow-up; an explicit check consumes a pending debounce timer, obsolete results are not published before an admitted follow-up, and automatic reloads recheck sync/action admission. Closing the page drops queued reloads (#79).

## [0.28.1] - 2026-11-17

### Bug fixes

- **Not synced** snapshots only structured error codes and string paths from completed sync reports before inspection. Unused nested diagnostics are neither traversed on the UI isolate nor sent to the mapping worker; exact-path failure attribution and pre-inspection snapshot semantics are unchanged. Required paths and full native plans still need copying; incremental inspection remains unfinished (#79).

## [0.28.0] - 2026-11-17

### Features

- Desktop and Android update prompts now share selectable Markdown release notes with headings, lists, emphasis, code and safe external HTTPS links. Long histories remain scrollable within 320 logical pixels; HTML stays literal, images never load, and parser failures show the original plain text (#154).

## [0.27.8] - 2026-11-17

### Bug fixes

- **Not synced** keeps current conflicts visible despite historical sync errors. Rename/move rows check both exact endpoints for errors and case collisions, preserve the destination, and describe failures as evidence from the last completed attempt rather than current transfer state (#79).

## [0.27.7] - 2026-11-17

### Bug fixes

- **Not synced** now lists skipped paths from the current read-only inspection rather than the last completed sync report. Removed skips disappear on refresh, newly skipped links appear before a sync, and a blocked root replaces exclusions without a false truncation warning (#79).

## [0.27.6] - 2026-11-17

### Bug fixes

- **Not synced** prepares immutable status counts and folder/status row projections once per refreshed snapshot on an entry-only worker after ordering. Page rebuilds and filter changes reuse those ordered lists instead of rescanning all retained entries. The global row cap, folder totals and truncation semantics are unchanged. Native inspection remains non-incremental; full input copying/freezing and result merging remain separate responsiveness work (#79).

## [0.27.5] - 2026-11-17

### Bug fixes

- **Not synced** maps native plans, selective exclusions and completed-attempt errors/skips and counts retained rows on a device-local worker isolate before the existing single final ordering worker. Each sequential folder worker receives only frozen config/report data, the native plan and the remaining global row budget; statuses, notices and truncation are preserved. Native inspection is still non-incremental, and full input copying/freezing, result merging and view filtering remain separate responsiveness work (#79).

## [0.27.4] - 2026-11-16

### Bug fixes

- Automatic desktop and Android update prompts can appear over device naming. Failed feed reads and unavailable prompts no longer consume the daily check gate; confirming the device retries a pending check immediately. Later/skip, automatic-check opt-out and manual checks remain available without changing installation behavior (#147).

## [0.27.3] - 2026-11-16

### Bug fixes

- **Not synced** orders its bounded result on a worker isolate instead of sorting each folder and the final list on the UI isolate. Folder/status/path order, retained-row counts and the truncation warning are preserved. Native inspection, row mapping and input copying still need separate incremental/responsiveness work (#79).

## [0.27.2] - 2026-11-16

### Bug fixes

- Device naming now suggests an unused portable label using locally decrypted account-root entries and shows existing names with collision markers. Errors and Reload preserve typed names. A definite guarded-rename 409 gets one fresh-snapshot retry; ambiguous transport/server failures are not retried. Confirmation reads back the target's encrypted label without bootstrapping another device space (#144).

## [0.27.1] - 2026-11-16

### Bug fixes

- **Not synced** folder totals no longer include storage-permission Blocked rows hidden by the global row limit; folder counts, status filters and the displayed total now describe the same retained rows. The existing truncation warning still signals omitted items (#79).

## [0.27.0] - 2026-11-16

### Features

- Private device naming (#140): after unlock, confirm an editable device name before the file browser, uploads or scheduled sync become available. Suggestions use Android's device name/model, Windows computer name or a meaningful desktop hostname, with a platform fallback. Labels are sealed in the existing device-root name; authentication sends only a generic device name. Confirmation is remembered for that server/account/device/root identity, not for a new device ID after sign-in.
- New uploads and folders from My files default to this device's space; Global is used only when explicitly opened. Renaming a device changes its encrypted space label, not node IDs, content versions, existing local paths or file locations. Legacy folders move only through the separate explicit move action.

### Bug fixes

- Migration 0008 replaces live plaintext device names with `Device` and normalizes legacy database writes to that placeholder while retaining the compatibility column and API fields. Existing encrypted root labels remain intact. Historical backups, WAL and old client requests may still contain former plaintext names; this is not secure erasure or protection from older servers receiving those requests.

## [0.26.1] - 2026-11-16

### Bug fixes

- **Not synced** now counts an unreadable, missing or invalid local sync tree as one **Blocked** folder row, with storage/drive guidance and the existing access action where available. Filesystem failures use diagnostic-free typed inspection codes rather than parsing errors; incomplete scans never produce deletion plans or contact the remote tree. Network and journal failures remain separate comparison notices. Fixed the inspection worker capturing an unsendable native library so these outcomes reach the overview.

## [0.26.0] - 2026-11-16

### Features

- Desktop **Not synced** row details now offer **Show local copy** when a fresh confined filesystem check finds the expected file or folder. Clicking rechecks the path and opens only its containing directory (or the folder itself), without syncing or launching the file. Missing, linked, unsafe and wrong-type paths disable the action; failures stay redacted and reload the overview. The older conflict-copy Show action uses the same guarded controller path, and session shutdown waits for admitted launch attempts.

## [0.25.0] - 2026-11-15

### Features

- Not synced actions (#79 partial): the **Not synced** view is now a place you can act from, not only read. A conflict row offers **Resolve conflict**, which shows both sides and asks for keep mine, keep theirs or keep both before anything is written; a retry or an access grant is one tap from the row. Every action reloads the list, and the view reloads by itself when a sync round finishes while it is open — never in the middle of a round — so the counts belong to the current state. A failed action says so and leaves the list intact. Nothing new leaves the device: the choice is applied by the existing sync engine, and names and paths stay local.

## [0.24.0] - 2026-11-15

### Features

- Complete paged rewind (#81 partial): a **Rewind to an earlier date** now covers every changed file, not only the first 200. The client reads the plan page by page (stopping after 25 pages so one confirmation stays bounded, with a **Load more changes** button for anything left), shows the whole plan before anything happens, and applies it in server-sized batches of up to 200 files in one confirmation. A page that repeats rows is never applied twice, and if the connection drops partway the dialog says how many files were already changed instead of claiming nothing happened.

## [0.23.0] - 2026-11-15

### Features

- Per-file version history and restore (#81 partial): a file's **Version history** action now opens a history that marks the version the file currently uses, shows when each earlier content was committed and how large it is, lets any earlier version be downloaded under its own dated name, and restores one after a confirmation. Restoring only points the file back at a version that already exists — nothing is uploaded, downloaded or deleted, every version stays listed, so you can switch back at any time. The server re-checks that the version belongs to this file and account, refuses a folder, a trashed file or a version whose content references are still pending, and tells the account's other devices to refresh; names are still decrypted only on the device.

## [0.22.0] - 2026-11-15

### Features

- Trash restore destination and folder-scoped rewind (#81 partial): when the folder an item was deleted from no longer exists, the Trash page now asks where to put it back — **My files**, or any folder chosen in a picker that lists fresh remote folders and opens their names only on the device — instead of offering only My files. The same picker narrows a **Rewind to an earlier date** from the whole account to one folder, and choosing a different folder plans again so the counts on screen always belong to the scope that would change. Nothing plaintext reaches the server, every listing stays owned by the unlocked session, and nothing changes until the plan is confirmed.

## [0.21.0] - 2026-11-15

### Features

- Bulk rewind (#81 partial): a **Rewind to an earlier date** action in the Trash page puts the account back to the newest version each file had on a chosen date, with 1-day, 7-day, 30-day and pick-a-date presets. The plan is always shown first — how many files would change, stay unchanged, were created after that date or cannot be rewound yet, plus the changed files by locally decrypted name — and nothing changes until you confirm. Rewinding only moves which existing version a file points at: versions after the date stay in history, nothing is uploaded or downloaded, items in the trash are untouched, and posted Usenet copies cannot be retracted. The server re-checks every item against a fresh preview, so a file that changed meanwhile is refused instead of being silently rewound, and files whose content references are still pending are skipped rather than served unsafely.

## [0.20.0] - 2026-11-15

### Features

- Trash retention is now enforced by the server (#81 partial): a daily background job permanently deletes the metadata of items that have been in the Trash longer than the retention window (30 days by default), so the deadline shown in the Trash page is real rather than only a limit on Restore. Each item is removed in its own account-scoped transaction and publishes a `purge` event, a still-restorable item is never touched, and a fixed account root or a folder that still holds live files is skipped instead of failing the sweep. This is metadata-only: articles already posted to Usenet cannot be retracted, and nothing claims that content disappeared.

## [0.19.0] - 2026-11-15

### Features

- Permanent delete and empty trash (#81 partial): the Trash page now has a **Delete permanently** action on every deleted item and an **Empty trash** action, each behind a confirmation dialog that says the removal cannot be undone. Deleting an item for good drops the account's own copy of its metadata, versions and names; files already posted to Usenet cannot be retracted, so nothing claims that content disappeared. The server refuses to remove a fixed account root or a folder that still holds live files.

## [0.18.0] - 2026-11-15

### Features

- Trash and restore (#81 partial): deleting a file or folder now moves it to a Trash you can restore from. The new **Trash** entry in the file browser lists every deleted item with its decrypted name, whether it is a file or a folder, the deletion date and the days left before the retention window closes (30 days by default). **Restore** puts the item back where it came from with its versions intact; if that folder is gone, the app offers to restore it to My files instead, and an item past the window stays visible but cannot be restored. Folder deletion works again and takes the whole folder and everything inside it at once, so nothing is left invisibly stranded. Deleted names are still decrypted only on the device, and deleting still never retracts articles already posted to Usenet.

### Tests

- Accessibility checks for the file browser (#78 partial): keyboard focus order, TalkBack names and 48dp touch targets are now pinned by tests, so a later layout change cannot silently break them.

## [0.17.2] - 2026-11-14

### Bug fixes

- Search filters stay on screen at 200% text (#78 partial): with the system text size doubled, the type and sync-status dropdowns on the search page ran past the right edge of a phone screen, so part of the filter row could not be read or reached. They now shrink and shorten their label instead of overflowing. The same pass adds widget tests for the sync folders page, the empty sync page, the search filters and results, and the rename and conflict-choice dialogs, all at 200% text, and pins WCAG AA contrast for the text colours the app paints.

## [0.17.1] - 2026-11-14

### Features

- TalkBack labels on file rows (#78 partial): each file or folder row now announces whether it is a file or a folder and whether it is a favourite, so a screen reader no longer depends on the shape or colour of the icons. A widget test also pins the browser to 200% text scaling to catch row overflow.

## [0.17.0] - 2026-11-14

### Features

- Update notes cover every version (#123): when an update is available, the Windows and Linux clients now show what changed in **each** release between the installed build and the newest one, not only the latest release's notes. Each version gets its own heading, newest first, in a scrollable prompt; releases without notes, prereleases and non-version tags are skipped, and the list is bounded so a long history cannot flood the window. The download still comes from the newest release with its `SHA256SUMS.txt` check, and a build newer than every published release still reports up to date.

## [0.16.0] - 2026-11-14

### Features

- Android Material 3 layout (#78 partial): the client now uses one theme for light and dark, taken from the brand colour, so the busy overlay and the "setup complete" tick follow dark mode instead of staying white and green. Dialog boxes stop growing past a readable width on tablets and in landscape. Android draws edge-to-edge with the status and navigation bar icons matching the theme. The file browser keeps a readable column instead of stretching a phone layout across a tablet or landscape window, and the new-item sheet stays above the keyboard. In the unlock screen the form scrolls when the keyboard covers it instead of clipping the **Unlock** button. TalkBack labels, 200% text scaling and installed-device acceptance remain open.

## [0.15.0] - 2026-11-14

### Features

- Android item menu (#78 partial): every file and folder now has one visible **More actions** menu instead of a row of cramped icon buttons. The same menu opens when a file is tapped, lists rename, move and copy for both files and folders, keeps the file's download, version and favourite actions, and asks for confirmation before deleting. An action that cannot run says why: actions are greyed out with **Finish the operation that is already running** while another operation runs, and folder deletion explains that it waits for Trash and restore (#81) instead of failing silently. Row actions keep a 48dp touch target. Material 3 layout, accessibility and installed-device acceptance remain open.

## [0.14.0] - 2026-11-14

### Features

- Android back navigation (#78 partial): system back in the file browser now leaves one folder at a time instead of dropping out of the unlocked account, and the app-bar control is labelled **Up one folder** so the gesture and the button agree. Opening a folder keeps its name in the title. Back inside the rename or new-folder dialog asks **Discard your text?** instead of silently throwing away typed input. Predictive-back preview and installed-device acceptance remain open.

## [0.13.0] - 2026-11-14

### Features

- Android in-app update check (#77 partial): **Check for updates** now works on Android. The app reads the same release feed as the desktop clients, compares Android version codes from a published `nntdrive-<version>-android.json`, downloads the APK and verifies its `SHA256SUMS.txt` digest before anything else happens. A release without a version code or checksum, or a download that does not match, is refused with a plain message. A verified package is handed to the Android installer, which asks the user to confirm; if **Install unknown apps** is off the app explains it once and offers the settings screen instead of looping. **Later** defers that version code only, startup checks at most once a day, and offline checks stay silent. Updates are never silent and nothing removes the account, keys or sync journal. A real in-place upgrade still needs a stable Android signing key, so that path remains open on the issue.

## [0.12.0] - 2026-11-14

### Features

- Android permission handling (#78 partial): storage refusals are now classified instead of treated as one failure. A first refusal stays retryable and keeps the folder usable, while a refusal the OS will not prompt about again — including every All files access refusal on Android 11+ — is reported as permanent, offers an **Open settings** action and stops repeating a prompt that cannot appear. The rationale dialog says up front that declining leaves the app usable and that app-private storage needs no permission.

## [0.11.0] - 2026-11-13

### Features

- Unsynced overview (#79 partial): the sync page opens a device-local **Not synced** list built from a read-only plan of the Rust sync engine. Every enabled folder is compared without uploading, downloading, deleting or writing the journal, and each item shows a text status — cloud only, local only, pending, failed, conflict, skipped or blocked — with a plain-language reason, its folder, its size and a folder-level retry; blocked items offer an access grant. Counts filter the list, an empty result says nothing is waiting to sync, and folders that cannot be compared, first-ever folders and pending folder moves are shown as notices instead of being reported as in sync.

## [0.10.6] - 2026-11-13

### Features

- Cross-device conflict handling for offline spaces (#95 partial): while the library is inside a space whose device is offline or revoked, a banner now says that the space stays usable, that changes made there are kept, and that a device reconnecting with its own unsynced change to the same file keeps both versions as a conflict copy — nothing is overwritten. Revoked spaces say that nothing on that device syncs the files again. Nothing is blocked, deleted or moved automatically, and the notice never guesses: a private folder or an unreadable space list shows no banner. Existing-account migration remains unimplemented.

## [0.10.5] - 2026-11-13

### Features

- Pre-spaces sync folder migration (#95 partial): a sync folder created before account spaces existed keeps its remote folder at the account root, and the spaces overview now lists those folders under **Folders outside your spaces**. Moving one into this device's space uses the same guarded move as the file manager, so the node, its sealed name, every version and its subtree stay unchanged and the local sync entry keeps working because it tracks the root node ID rather than a path. A destination name collision, a changed source or an unreachable server stops without overwriting or deleting anything, the destination is never Global or another device's space, and nothing moves automatically. Stale-device conflict handling remains unimplemented.

## [0.10.4] - 2026-11-13

### Features

- Selective-sync clarity for the shared space (#95 partial): when a sync folder mirrors the account-wide **Global** space and subfolders are excluded, the selective-sync dialog now says Global is no longer fully shared and the folder card carries a matching "Not fully shared" marker; excluded paths stop synchronizing in both directions, so other devices no longer receive changes to them and their remote changes are no longer applied here. Nothing is deleted or silently unsynced, and a device space, a private folder or an unreadable space list is never guessed to be Global. Stale-device conflict handling and existing-account migration remain unimplemented.

### Bug fixes

- The 0.10.3 version bump also rewrote three third-party `Cargo.lock` entries (`chacha20`, `pkcs8`, `rand_pcg`) to the project version, so the release workflow could not resolve dependencies and published nothing. The pins are restored; 0.10.4 is the first release containing the selective-sync change. The `v0.10.3` tag is left in place and is not a published release.

## [0.10.2] - 2026-11-13

### Features

- Offline move queuing (#95 partial): a move chosen while the server cannot be reached is now saved on this device instead of failing, and applied automatically on the next unlock or sync. Only opaque node IDs and the sealed name ciphertext are stored; replay re-runs the same guarded move, so a destination collision, a source moved or renamed by another device, or a lost reply is detected instead of overwriting anything. An unacknowledged attempt that already landed is recognised from the destination listing and not applied twice. Entries stop retrying after a conflict and are listed on the sync page with a discard action; an unreachable server keeps the queue in order. The queue is bounded, and copies, renames and deletes are not queued. Selective-sync interaction, stale-device conflict handling and existing-account migration remain unimplemented.

## [0.10.1] - 2026-11-13

### Features

- Space-aware move destinations (#95 partial): the move and copy picker now labels each fixed account space (`Global space · synced on every device`, `Device space · on demand on this device`, plus offline and revoked markers), and moving an item out of **Global** into a device space asks for confirmation first, because that item stops syncing automatically to the other devices. Copies and moves that stay inside Global are not confirmed. Space metadata is advisory: when the spaces cannot be read, the picker moves files exactly as before. Offline move queuing, selective-sync interaction and stale-device conflict handling remain unimplemented.

## [0.10.0] - 2026-11-13

### Features

- Space subscriptions (#95 partial): the account-wide **Global** space is now mirrored automatically on every device at `<documents>/NNTDrive/Global`, so a new client receives it without the user adding a folder; any other space can be subscribed on demand from the Account spaces overview and stopped again without deleting files. A removed Global subscription stays opted out across restarts, unsafe device names cannot escape the spaces directory, and a subscription error is reported without dropping the entry.

## [0.9.7] - 2026-11-13

### Features

- Per-device sync destinations (#95 partial): a sync folder added on a device is now created inside that device's own fixed account space instead of at the account root, so two devices adding a folder with the same local name no longer share one remote path. When the account has no usable device space (a sign-in that cannot create one, or no current-device identity) the folder stays at the account root and the status line says so; the sealed name stays bound to the node ID that was sent. Cross-device move, Global auto-mirroring and existing-account migration remain unimplemented.

## [0.9.6] - 2026-11-12

### Features

- Client account spaces (#95 partial): after unlock the app now bootstraps the fixed Global space and this device's space, sealing each root name for a client-chosen node ID, and lists every account space in a new **Account spaces** overview on the sync page. The overview names the device behind each space and marks offline or revoked devices instead of hiding them; failures are reported with a retry and never block folder sync. Global auto-mirroring, device auto-subscription, per-device sync destinations, cross-device move and existing-account migration remain unimplemented.

## [0.9.5] - 2026-11-12

### Bug fixes

- Upgrade the NZB XML parser to quick-xml 0.41.0 while retaining duplicate-attribute checks; malformed/duplicate attributes on parsed file, segment and metadata tags now return errors. Preserve entity-containing metadata and article IDs with the newer streaming API (#16 partial).

## [0.9.4] - 2026-11-12

### Bug fixes

- Fixed account roots (#95 partial): `POST /roots` now requires the client-chosen `node_id` that the sealed root name is bound to. A server-chosen ID left every stored root envelope unopenable, because names are sealed with the node ID as authenticated data. A missing or nil `node_id` is refused with `400` and an already-used one with `409`; repeat and second-client bootstrap still converge on the original root and envelope, which every client can open. Client bootstrap, auto-subscription and the device list UI remain unimplemented.

## [0.9.3] - 2026-11-12

### Features

- Backend fixed account roots (#95 partial): one Global root per account and one root per registered device, created idempotently by an unlocked client with a client-sealed name. All clients converge on the same node ID and envelope, device roots require a device-bound token, roots are listed with device/stale state, and rename/move/delete of a fixed root is refused with `409`. Client auto-subscription, per-device sync destinations and cross-device move are not implemented yet.

## [0.9.2] - 2026-11-12

### Bug fixes

- Account-search status refresh validates portable names, computes native canonical comparison keys and groups ambiguous siblings off the UI isolate (#80 partial). One refresh-owned worker consumes sequential batches of at most 128 scalar name records and finalizes safety only after the complete snapshot, preserving cross-batch collisions and ancestor rejection. Close discards late evidence and drain awaits worker completion. Report freezing/error-set construction, ancestry walks, conflict/filesystem inspection and final snapshot merging remain caller-side; this is not full cold-build isolation or installed performance acceptance (#93).

## [0.9.1] - 2026-11-12

### Bug fixes

- Account-search refresh indexes structured sync-error paths once per frozen root rather than rescanning complete reports for every result (#80 partial). Exact-path matching, conflict/transfer precedence and refresh-only semantics are unchanged. Index construction yields and observes cancellation within reports and large path lists; whole-report copying and conflict inspection remain caller-side, and installed performance remains unverified (#93).

## [0.9.0] - 2026-11-12

### Features

- Account search combines refresh-time Unknown/Local/Cloud only/Not covered/Syncing/Conflict/Error filters with existing name, metadata and favorite filters, including session-local saved/recent combinations (#80 partial). Observations reuse confined filesystem inspection and authenticated snapshot ancestry with canonical sibling-collision checks, publish atomically inside session build ownership and never imply that disk presence is verified sync equality. Status remains explicitly stale after sync/disk changes until refreshed; no local paths or diagnostics are added to results or requests.

## [0.8.10] - 2026-11-11

### Bug fixes

- Reissue the bounded search traversal-worker change from v0.8.9 under a fresh patch tag. The v0.8.9 Release workflow built the Windows and Android clients but failed uploading their artifacts after five service-response retries, so no GitHub release was published. The original tag is unchanged. This patch changes version metadata only; it does not claim to fix GitHub's artifact service or complete broader search scope (#80).

## [0.8.9] - 2026-11-11

### Bug fixes

- Account-search builds validate parent membership, within-batch duplicates, count/depth bounds and discover ordered directory IDs on worker isolates in sequential batches of at most 128, before name reuse/decryption (#80 partial). Close/drain owns validation completion and failed refreshes retain the last complete snapshot. Cross-batch/global membership checks, reuse selection, queue updates, transport collection/copying and candidate-map merging remain caller-side; this is not whole-build isolation or a speedup/installed-device performance claim.

## [0.8.8] - 2026-11-11

### Bug fixes

- Account search now coalesces typing with a 40 ms delay instead of 180 ms, leaving time for worker scanning and rendering within the responsiveness target. Explicit searches and other immediate query actions cancel a pending typing request rather than dispatching it again (#80 partial). This is a UI scheduling fix, not installed-device p95 performance acceptance (#93).

## [0.8.7] - 2026-11-11

### Bug fixes

- Reissue the bounded worker-isolate search-listing change from v0.8.6 under a fresh patch tag. The v0.8.6 Release workflow failed while loading the Android smoke test with `VmServiceDisappearedException` after APK installation and did not publish client assets; the original tag is unchanged. This patch changes version metadata only, not Android runtime behavior; hosted-runtime investigation remains #64.

## [0.8.6] - 2026-11-11

### Bug fixes

- Account-search listings now collect at most 64 MiB of response body bytes per folder and decode UTF-8/JSON plus construct up to 100k opaque file models on a worker isolate (#80 partial). HTTP/parser failures are redacted, unrelated listing callers are unchanged, and close/drain retains parsing until completion before key revocation. Traversal/validation, byte collection/copying and final candidate-map merges remain caller-side; status filters, encrypted persistence and installed-device acceptance (#93) remain unfinished.

## [0.8.5] - 2026-11-11

### Bug fixes

- Account search now refreshes on every opening of the search page instead of showing an old snapshot until a manual rebuild, and reruns the current query/filter when a complete snapshot is published, including rebuilds started outside the page. A failed refresh keeps the last complete snapshot searchable, shows an explicit stale warning and clears it after a successful retry; history-only notifications no longer wipe results or trigger extra queries, a delayed result can no longer overwrite a newer snapshot, and closing during a refresh leaves no results behind (#80 partial). This is not continuous or event-driven freshness: there is no polling, SSE subscription, background sync or sync-status evidence, and entry/refresh still lists and parses the whole account tree.

## [0.8.4] - 2026-11-11

### Bug fixes

- Account-search builds now construct entries, lowercase names and assemble bounded entry maps on worker isolates, in sequential batches of at most 128, including reused authenticated names (#80 partial). Complete snapshots still publish atomically and session drain awaits workers before key revocation. HTTP parsing, traversal/validation and final candidate-map merging remain caller-side; this is not a fully isolated cold build or installed-device performance acceptance.

## [0.8.3] - 2026-11-11

### Bug fixes

- Explicit account-search rebuilds reuse names already authenticated in the same session only when both node ID and encrypted envelope match. Fresh complete tree listings still replace metadata, ancestry and membership atomically; changed names are authenticated again and failed refreshes retain the last complete snapshot (#80 partial). This does not add automatic event refresh or durable index persistence.

## [0.8.2] - 2026-11-10

### Bug fixes

- Account-search query scanning, filtering and bounded top-200 ranking run on worker isolates, with serialized dispatch, stale-result rejection and complete session drain ownership (#80 partial). Per-query snapshot-copy/spawn costs remain; HTTP parsing, cold folding/assembly, status filters, persistence and incremental refresh are not addressed.

## [0.8.1] - 2026-11-10

### Bug fixes

- Account-search cold builds open authenticated encrypted names on worker isolates in sequential batches of at most 128, draining worker completion before session key revocation (#80 partial). HTTP parsing, snapshot assembly and ranking are not moved off the UI isolate; status filters and encrypted persistence remain unfinished.

## [0.8.0] - 2026-11-10

### Features

- Search decrypted names across all account folders using an explicitly rebuildable, session-memory-only client index (#80 partial). Ranked results include containing folders and sizes, with combined type, extension, size, server modification-date and favorite filters; recent searches and saved filters last until sign-out. Indexed results remain searchable offline within that unlocked session. Search availability/sync-status filters and durable encrypted offline persistence remain unfinished.

## [0.7.1] - 2026-11-10

### Bug fixes

- Windows updater launches a hidden PowerShell child with an explicit UTF-16LE encoded command instead of Dart's detached creation flags, retains startup error output and the helper PID, and exercises handoff across real parent exit with a compiled executable regression (#49). Installed-release acceptance remains separate.

## [0.7.0] - 2026-11-09

### Features

- Fresh image-only installations can start with an absent/empty `.env` using `nntdrive-compose.py`: database and provider-encryption secrets are generated once, privately persisted, and reused. Missing/corrupt secrets with existing data fail closed; explicit credentials cannot silently rotate saved values (#62).

### Bug fixes

- Android folder sync requests explicit storage access with denial/retry guidance and a permission-free app-private alternative; revoked/unreadable roots no longer look like successful empty scans (#69). Shared folders use Android's all-files grant, not per-tree SAF isolation; installed-device acceptance remains separate.
- Live sync event streams recheck the original credential and account/device status with a two-second authorization lease, closing after logout, revocation, disable or expiry (#16 partial). Already admitted/buffered frames cannot be retracted.

## [0.6.0] - 2026-11-09

### Features

- Manage encrypted files from the client: rename files and folders, move them to another folder, and copy files or whole folder trees. Names stay encrypted end to end, and renames propagate as moves instead of delete/re-upload (#51 partial).
- The file browser shows whether an item is local, cloud-only, syncing, conflicted or failed, and can reveal a locally synced file in the OS file manager.
- Admin provider changes (add, edit, remove) apply to the running backend without a restart; retention and article-age refresh policies are stored and their maintenance results shown in the dashboard.
- Optional per-account orphan metadata cleanup with a 1-3650 day grace period, reference-aware commit fences and protected retained history. Usenet articles are never retracted; upgrade clients before opting in.
- Windows/Linux close-to-tray keeps one unlocked sync session with open, pause/resume and quit, and drains active work before locking keys (#6 partial).
- Sync rounds and conflict resolution reject a second process using the same journal and release operation leases after cancellation or process death.

### Bug fixes

- Harden account admission with one transaction-scoped database gate and bound yEnc decoded allocation/output by input and declared length (#16 partial).
- File and folder copy quota checks reuse the publication transaction's connection, so concurrent copies no longer exhaust the database pool.
- File rename, move and copy now reject Unicode and Windows-invalid names, keep conflict labels when the original is missing, avoid false conflicts for identical edits, and scope syncing/error labels to the affected item (#51 partial).
- The locked-vault screen states that synchronization is paused until unlock instead of implying background sync is running.

## [0.5.2] - 2026-11-08

### Features

- Release downloads now name each client asset with its version and platform: `nntdrive-<version>-linux-x64.tar.gz`, `nntdrive-<version>-windows-x64.zip` and `nntdrive-<version>-android.apk`. Checksums cover those names, and desktop downloads keep the unversioned names as aliases so older auto-updaters can still find them.

## [0.5.1] - 2026-11-07

### Features

- Guided README installation and usage steps cover release downloads, server setup, offline recovery material, client connection, folder sync and conflicts (#52).

### Bug fixes

- Desktop updater waits for the detached helper to start before exiting. Windows additionally requires a bounded preflight acknowledgement, preserves step diagnostics and payload backups, verifies copied files, and attempts rollback/restart with a visible failure dialog after replacement errors. Installed-build Windows acceptance remains pending (#49/#28).

## [0.5.0] - 2026-11-06

### Features

- Sync shows per-file logical byte progress from confirmed encrypted chunk publication/deduplication and verified download writes through the native bridge, with commit/verification distinguished from byte completion.
- Conflict review offers Keep mine, Keep theirs and Keep both. Both versions remain in ordinary synced recovery/kept files; stale local hashes or remote revisions require another sync/review instead of overwriting edits.

### Bug fixes

- Enabled desktop update checks now run on every app launch, even after a recent check, and daily while the app stays open. Later suppresses only that version's automatic prompt; checks continue. Automatic and manual checks cannot overlap or open duplicate prompts, and failures stay non-blocking.
- Remote folder renames now move the local subtree using stable remote node IDs, preserving baseline revisions and empty directories instead of deleting/recreating children. Interrupted local moves recover from a durable journal intent; destination collisions and selective-sync intersections stop safely without overwriting content.

## [0.4.1] - 2026-11-05

### Bug fixes

- Update settings can test the repository and token before saving, and reports permission errors clearly instead of suggesting a rebuild.
- A 401 from GitHub now says the token was rejected rather than showing a generic failure.

## [0.4.0] - 2026-11-05

### Features

- Windows and Linux clients expose **Account → Update settings**: release repository, optional read-only access token for the private repository, and the daily auto-check toggle.
- The saved token is used for both the release check and private asset downloads; clearing the field removes it.
- Update checks can now run against private releases without rebuilds that embed a token.

## [0.3.0] - 2026-11-05

### Features

- Windows and Linux clients check GitHub Releases for new versions at most once a day, and expose **Check for updates** in the account menu.
- Updates are downloaded over HTTPS, verified against the release's `SHA256SUMS.txt`, then replaced in place and restarted by a detached helper after the app exits.
- The release workflow now publishes `SHA256SUMS.txt` for the Linux, Android and Windows assets.
- Private builds can point the updater at another repository or supply a read-only token with `--dart-define=NNTDRIVE_UPDATE_REPO=...` and `--dart-define=NNTDRIVE_UPDATE_TOKEN=...`; public releases need neither.

## [0.2.1] - 2026-11-04

### Features

- GitHub releases now include client builds alongside the backend image: a Linux x64 tarball, an Android APK and a Windows x64 zip.
- The release pipeline reuses the client workflow, so published clients are built from the same tag as the backend.

### Bug fixes

- Release creation no longer fails on a malformed shell heredoc in the notes/upload step. Client artifacts are downloaded and attached even when the Windows build is skipped by the runner.

## [0.2.0] - 2026-11-04

### Features

- Sync now streams file content through the HTTP remote adapter instead of buffering whole files in memory, making large-file sync practical.
- Remote content hashes are cached locally, enabling remote file-rename detection and same-content convergence.
- Selective sync: exclude subfolders per sync root; exclusions apply to local scanning and the remote snapshot, so excluded content is neither uploaded nor downloaded.
- Conflict review: the sync screen lists conflict copies with a badge and count, and can reveal each one in the file manager.
- The admin dashboard can edit existing users: display name, quota (including restoring unlimited storage), administrator role and enabled/disabled status.
- Usenet providers can be edited in place (host, port, TLS, credentials, type, priority, groups, connections, retention and enabled) without deleting and recreating them. Leaving the password blank keeps the stored one.
- Provider type is now a dropdown (both, posting only, retrieval only).
- The dashboard overview is condensed, and provider configuration and live traffic counters share one table.

### Bug fixes

- Sync folder removal now also deletes the remote-hash cache.
- Excluding a folder that was already synced keeps its baseline history, so re-enabling it does not create conflicts or duplicate uploads.
- Administrators can no longer remove their own admin role (previously this could leave an instance with no administrator).

## [0.1.0] - 2026-11-04

### Features

- End-to-end encrypted, chunked storage on Usenet with per-chunk XChaCha20-Poly1305 encryption, encrypted names, sealed manifests and a documented key hierarchy.
- Reed–Solomon erasure coding (default 30% redundancy) with artifact verification before every metadata commit.
- Self-healing storage: article health checks, stripe repair, retention refresh, read-back verification and honest unrecoverable reporting.
- Real NNTP/TLS posting and retrieval with pooling, retries, yEnc, NZB and multiple providers (separate posting/retrieval roles).
- PostgreSQL metadata, immutable versions, audit-friendly shard history and durable background jobs.
- Multi-user Axum backend with Argon2 verifier login, device tokens/revocation, tenant isolation, quotas and admin API.
- Embedded admin dashboard with storage/article health, provider test, article verification, job controls and one-click graceful restart.
- First-run onboarding: the app creates the first administrator locally and presents a one-time admin token plus recovery code.
- Flutter clients for Windows, Linux and Android with browse, upload, download, version history, favorites, delete and encrypted-name display.
- Multi-folder bidirectional sync: base + additional folders, automatic 5-minute runs, pause, manual sync and conflict copies.
- Folder structure represented only in client-encrypted metadata; no folder names or paths are sent to the backend or Usenet.
- Docker Compose deployment, Caddy TLS profile, health checks, backup/restore scripts, systemd unit and CI.
- Versioned multi-arch-ready backend images published to GHCR with semantic tags and SBOM/provenance.
- Standalone NNTP article verifier and image-only deployment files for no-clone installs.

### Bug fixes

- Fixed Rustls panic when both aws-lc-rs and ring were enabled by selecting a crypto provider explicitly.
- Fixed Eweka posting failures caused by an invalid `From` header and by using the retrieval host for posting.
- Fixed an admin dashboard crash (`SUM(bigint)` returns `numeric`) that appeared as “Failed to fetch”.
- Fixed sync directory handling that treated remote folders as downloadable files and produced false conflicts.
- Fixed false “remote modified” conflicts when the server did not provide a content hash.
- Added the missing Android `INTERNET` permission and local cleartext support for development builds.
- Fixed the release workflow manually after an initial release-asset shell-continuation failure; future releases validate notes and assets in CI.
