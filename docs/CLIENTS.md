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
2. selects `nntdrive-windows-x64.zip` or `nntdrive-linux-x64.tar.gz`;
3. downloads over HTTPS and verifies the SHA-256 from `SHA256SUMS.txt`;
4. unpacks to a temporary directory and starts a detached helper;
5. exits, letting the helper replace the install directory and restart the app.

The helper launch is awaited before the app exits. On Windows, the helper must
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
`failed`/`complete` records the outcome, `update.ps1` retains the helper source,
and `backup/` retains overwritten files. Failed stages/backups are deliberately
not deleted. These files contain local install paths, not update tokens or keys;
review/redact paths before sharing a log. After confirming a working install,
these temporary directories and the matching staged update can be removed
manually. Installed-release version/data/journal preservation and locked-file
manual acceptance remain #49/#28; hosted helper fixtures do not replace them.

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
Move/copy and installed Windows/Linux plus two-device UI acceptance remain
outstanding; existing sync tests are not a substitute.

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
exceptions and scan skips are not per-item failures. Full journal/revision
reconciliation for browser labels remains future work; missing originals without an attributed
failure are still labelled Cloud only.

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
- Android scoped storage prevents free filesystem access outside user-granted
  trees (`ACTION_OPEN_DOCUMENT_TREE`).
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
