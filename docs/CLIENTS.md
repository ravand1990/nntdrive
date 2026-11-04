# Client platforms

## Current state

| Platform | Source | Build status | Crypto/sync |
|---|---|---|---|
| Windows 10/11 | Flutter scaffold | Not built in this environment (no Flutter SDK) | ❌ Rust bridge missing |
| Linux desktop | Flutter scaffold | Not built in this environment | ❌ Rust bridge missing |
| Android | Flutter scaffold | Not built (no Flutter/Android SDK) | ❌ Rust bridge missing |
| iOS | Flutter scaffold | Not built (no macOS/Xcode) | ❌ Rust bridge missing |

The shared Rust engine (`crates/sync`, `crates/crypto`, `crates/storage`) is
implemented and tested. The Flutter app (`clients/flutter`) is a **UI and API
scaffold**: it can authenticate with a developer API token and browse encrypted
metadata. It deliberately disables password login, upload, download, decryption
and sync because the Rust↔Dart bridge is not built. The build workflow in
`.github/workflows/clients.yml` is marked non-blocking for this reason.

This is stated in the app UI as well, so the scaffold is not presented as a
finished client.

## What the Rust bridge must export

1. `derive_auth_verifier(password, account_id)` — Argon2id; never send the
   password.
2. `unlock_keyfile(keyfile_json, password)` and `unlock_recovery_kit(kit, code)`
   returning an opaque key handle. Store the wrapped keyfile in the platform
   keystore, not in shared preferences.
3. `prepare_chunk(handle, bytes)` — compress + encrypt; return ciphertext, hash,
   length, codec. The Dart layer must never implement crypto itself.
4. `seal_manifest`, `open_manifest`, `seal_name`, `open_name`.
5. `start_sync(server, token, root, options)` — run `nntdrive_sync::SyncEngine`
   with an HTTP `Remote` adapter and emit progress/conflicts over a stream.
6. Key epoch rotation and device enrollment wrapping.

Recommended: `flutter_rust_bridge` (build scripts for Android NDK, iOS,
Windows, Linux) or a small C ABI with `dart:ffi`. Pin the Rust toolchain and
include the `.so`/`.dll`/`.dylib`/XCFramework in the respective platform build.

## Build instructions (after the bridge exists)

### Linux

```bash
sudo apt-get install -y libgtk-3-dev libfuse3-dev ninja-build clang cmake
cd clients/flutter
flutter pub get
flutter build linux --release
```

FUSE requires `/dev/fuse`, the `fuse3` package, and either a setuid `fusermount3`
or a user_allow_other setup. A virtual drive is a separate mount process; the
Flutter app only configures it.

### Windows

```powershell
choco install visualstudio2022buildtools winfsp
cd clients\flutter
flutter pub get
flutter build windows --release
```

WinFsp: install the WinFsp runtime, ship `winfsp-x64.dll`, and install a
filesystem service (WinFsp.Launcher or a service wrapper). A non-elevated
desktop app cannot mount a drive letter without the WinFsp service; document the
elevation step. Cloud Files API (cfapi) is an alternative but requires a sync
root registration and a privileged installer.

### Android

```bash
cd clients/flutter
flutter build apk --release   # or appbundle
```

Requirements for the missing integrations:

- **DocumentsProvider**: implement a `ContentProvider` subclass in Kotlin,
  declared in the manifest with `android:grantUriPermissions="true"`,
  `android:exported="true"`, and the `DocumentsProvider` intent filter. All file
  I/O must go through the Rust core; do not duplicate crypto in Kotlin.
- **Photo backup**: `MediaStore` queries + `WorkManager` with network and
  charging constraints. Android 13+ requires `READ_MEDIA_IMAGES/VIDEO`.
  `JobScheduler`/`WorkManager` are inexact; the OS may defer background sync.
- **Background**: use a foreground service with a persistent notification for
  long transfers; declare `FOREGROUND_SERVICE_DATA_SYNC` (Android 14+).

### iOS

```bash
cd clients/flutter
flutter build ios --no-codesign   # requires macOS + Xcode
```

Requirements and hard limits:

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

## Sync model on clients

- One device-local SQLite journal (`nntdrive-sync`) holds the baseline.
- Scan on startup, on filesystem notifications (desktop), and periodically.
- `pause/resume` only pauses the scheduler; in-flight transfers complete or
  cancel safely.
- Conflict copies are visible in the file list after decryption; the UI should
  offer "keep mine", "keep theirs", "keep both" but must not silently discard.
- Selective sync is a per-folder include list stored in the journal; excluded
  folders appear as placeholders in the virtual drive.

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
