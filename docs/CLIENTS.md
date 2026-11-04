# Client platforms

## Current state

| Platform | Source | Build status | Crypto/content |
|---|---|---|---|
| Windows 10/11 | Flutter + Rust FFI | ✅ release build verified, DLL bundled, app launches | ✅ works end-to-end |
| Linux desktop | Flutter + Rust FFI | ✅ release build and headless launch verified | ✅ works end-to-end |
| Android | Flutter + Rust FFI | ✅ release APK verified (arm64, armv7, x86_64 libs embedded) | ✅ works end-to-end |
| iOS | Flutter | Not built (no macOS/Xcode in this environment) | Rust static lib needs an XCFramework; File Provider still missing |

`flutter analyze` is clean, 3 Dart tests pass (including a test that loads the
real Rust FFI library), and the Linux/Android clients were exercised through the
exact Dart FFI layer against a running backend: register → create file → upload →
download → decrypt → byte-for-byte verify.

The shared Rust engine (`crates/ffi`, `crates/client`, `crates/sync`,
`crates/crypto`, `crates/storage`) does all cryptography and content handling.
Dart never implements crypto; it passes UTF-8 JSON to the native core.

## Implemented in the client

- Account creation (keyfile + recovery kit + Argon2 verifier) and login.
- Encrypted password unlock; recovery code shown once at registration.
- Browse folders, decrypt names locally, search/filter.
- Create folders, upload files, download + verify, version history with
  per-revision download, delete, favorites.
- Multi-folder bidirectional sync: select a base folder plus additional folders,
  automatic runs every 5 minutes while the app is open, pause/resume, per-folder
  and global “Sync now”, conflict copies preserved, local plaintext by default.
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
isolate. The sync engine (`crates/sync`) is still driven by Rust tests only.

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

Android note: `AndroidManifest.xml` currently sets `usesCleartextTraffic="true"` so
the app can reach a local HTTP dev server (and the INTERNET permission is present
in release builds). Remove that flag and use HTTPS for any real deployment.
On a phone, `127.0.0.1` means the phone itself; enter the PC's LAN IP and allow
the port through the host firewall.
