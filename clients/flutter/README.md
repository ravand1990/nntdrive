# NNTDrive Flutter client

Working client for Linux and Android, backed by the shared Rust core
(`crates/ffi`). The UI never implements cryptography.

## Features

- Account creation with recovery kit + one-time recovery code, and password
  login (Argon2id verifier; password never leaves the device).
- Encrypted name decryption, folder navigation, filter/search.
- Create folders, upload files, download and verify, upload new versions,
  version history with per-revision download, delete, favorites.
- Device list/revocation, quota display, light/dark/system theme.
- All content operations run in a Dart isolate calling Rust; the UI stays
  responsive during transfers.

## Not yet implemented

Automatic folder sync, virtual drives, Android DocumentsProvider/photo backup,
iOS File Provider/background sync, sharing UI, iOS build. Windows sources are
ready but the build host needs Developer Mode (Flutter plugin symlinks) and the
Rust DLL.

## Build

Linux + Android (verified):

```bash
export ANDROID_SDK_ROOT=/opt/android-sdk
export NDK_HOME=$(ls -d "$ANDROID_SDK_ROOT"/ndk/* | sort -V | tail -1)
bash scripts/build-clients.sh
```

Artifacts:

- Linux: `build/linux/x64/release/bundle/` (run `./nntdrive`)
- Android: `build/app/outputs/flutter-apk/app-release.apk`

Windows (after enabling Settings → System → For developers → Developer Mode):

```powershell
cargo build --release -p nntdrive-ffi
copy target\release\nntdrive_ffi.dll windows\runner\
cd clients\flutter
flutter build windows --release
```

## Test

```bash
# with the Rust core built:
NNTDRIVE_FFI_PATH=$PWD/linux/lib/libnntdrive_ffi.so flutter test
```

The native test covers account creation, unlock, name sealing/opening and
wrong-key rejection. A full headless client smoke test against a live backend is
in `tool/native_smoke.dart`:

```bash
dart run tool/native_smoke.dart http://127.0.0.1:18080 /tmp/file.bin
```

## Architecture

`lib/native.dart` loads the Rust library (`dart:ffi`), passes UTF-8 JSON, and
keeps only integer key handles in Dart. `lib/api.dart` talks to the backend;
names/manifests arrive sealed and are opened in Rust. Uploads are client-side
encrypted; the backend only sees ciphertext.
