# Changelog

All notable changes are documented here. Every release tag **must** have an
entry with `### Features` and/or `### Bug fixes` (at least one bullet). The
release workflow refuses to publish if the entry is missing.

## [Unreleased]

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
