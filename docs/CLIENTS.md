# Client platforms

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
  per-revision download, delete, favorites.
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

## Account-wide search (#80 partial)

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
and an honest **Sync status unknown** label. Selecting a result navigates through
the existing browser, refreshing before offering file actions. Offline searching
works on the existing snapshot; opening/refetching an item still needs the server.

Combine file/folder type, filename extension, minimum/maximum bytes, **Favorites**,
and modification dates. Favorites come from actual namespace listings, not inferred
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

Not complete #80: sync/availability filtering and verified result-state badges,
durable encrypted offline persistence/history and automatic event refresh remain
unfinished. Freshness is entry/rebuild-triggered only: there is no polling, SSE
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

Transport byte collection/concatenation, worker input copying, fresh
traversal/validation, reuse selection, queue updates and final candidate-map
merges remain on the UI isolate, with cooperative ~4 ms slice yields in traversal.
Worker spawn/send overhead and temporary decoded JSON/model memory remain; this
is not a fully off-isolate cold build or installed-device responsiveness
acceptance (#93).
Builds reject malformed/unreadable trees and bounds above 100k
entries/depth 256 without replacing the previous complete index. Synthetic warm
query tests are not installed-device/cold-network performance acceptance. No
content extraction or server-side plaintext search is introduced.

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

No login autostart, cold-start automatic unlock or mobile background worker is
registered. A cold process still requires the password. See
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

1. reads `releases/latest` and compares the tag with the installed version;
2. selects `nntdrive-<version>-windows-x64.zip` or
   `nntdrive-<version>-linux-x64.tar.gz`, falling back to the unversioned name
   used by older releases;
3. downloads over HTTPS and verifies the SHA-256 from `SHA256SUMS.txt`;
4. unpacks to a temporary directory and starts a detached helper;
5. exits, letting the helper replace the install directory and restart the app.

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
`--dart-define=NNTDRIVE_UPDATE_REPO=owner/repo`. Android and iOS are not updated
by this mechanism (Android requires the system package installer; iOS requires
App Store/TestFlight or a signed enterprise install).

## Rename in the file browser (#51 partial)

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
