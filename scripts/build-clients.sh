#!/usr/bin/env bash
# Builds the Rust client core and the Flutter clients for Linux and Android.
#
# Requirements: Rust stable + cargo-ndk, Flutter, Android SDK/NDK, Linux GTK
# desktop toolchain. Windows and iOS are intentionally not handled here (see
# docs/CLIENTS.md); Windows requires Developer Mode and iOS requires macOS.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
flutter_bin="${FLUTTER_BIN:-flutter}"
cargo_bin="${CARGO_BIN:-cargo}"
android_sdk="${ANDROID_SDK_ROOT:-/opt/android-sdk}"
ndk="${NDK_HOME:-$(ls -d "$android_sdk"/ndk/* 2>/dev/null | sort -V | tail -1)}"
target_dir="${CARGO_TARGET_DIR:-$HOME/target-nntdrive}"

cd "$root"
echo "== Rust FFI (Linux) =="
CARGO_TARGET_DIR="$target_dir" "$cargo_bin" build --release -p nntdrive-ffi
mkdir -p clients/flutter/linux/lib
cp "$target_dir/release/libnntdrive_ffi.so" clients/flutter/linux/lib/libnntdrive_ffi.so

if command -v cargo-ndk >/dev/null && [[ -n "${ndk:-}" && -d "$ndk" ]]; then
  echo "== Rust FFI (Android: arm64, armv7, x86_64) =="
  CARGO_TARGET_DIR="$target_dir" NDK_HOME="$ndk" "$cargo_bin" ndk \
    -t arm64-v8a -t armeabi-v7a -t x86_64 \
    -o clients/flutter/android/app/src/main/jniLibs \
    build --release -p nntdrive-ffi
else
  echo "!! cargo-ndk or Android NDK not found; skipping Android FFI" >&2
fi

cd clients/flutter
"$flutter_bin" pub get
"$flutter_bin" analyze
echo "== Flutter tests (with native bridge) =="
NNTDRIVE_FFI_PATH="$root/clients/flutter/linux/lib/libnntdrive_ffi.so" "$flutter_bin" test

echo "== Linux release build =="
"$flutter_bin" build linux --release
cp "$root/clients/flutter/linux/lib/libnntdrive_ffi.so" \
   build/linux/x64/release/bundle/lib/libnntdrive_ffi.so

if [[ -d "$android_sdk" ]]; then
  echo "== Android release APK =="
  ANDROID_SDK_ROOT="$android_sdk" ANDROID_HOME="$android_sdk" "$flutter_bin" build apk --release
fi

echo
echo "Artifacts:"
echo "  Linux:   clients/flutter/build/linux/x64/release/bundle/"
echo "  Android: clients/flutter/build/app/outputs/flutter-apk/app-release.apk"
