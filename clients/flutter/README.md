# NNTDrive Flutter client (UI/API scaffold)

**Status: UI preview, not a working client.** The Rust cryptographic/sync bridge
is not wired, so this app deliberately disables password login, encryption,
upload, download, preview, file names and synchronization. It can sign in with a
developer API token and browse encrypted metadata. See `docs/CLIENTS.md` and
`docs/STATUS.md`.

## What works in the scaffold

- Server URL + developer API token sign-in (`nntdrive token-create`).
- Account/quota display, encrypted folder browsing, sealed-size display.
- Version metadata dialog and device list/revocation.
- Light/dark/system theme, persisted server and token.
- `flutter analyze` clean and two tests passing.
- Generated runners: Linux, Android, Windows (iOS needs `flutter create` on macOS).

Verified builds in this environment: `flutter build linux --debug` and
`flutter build apk --debug`. The Windows debug build is blocked by the host's
Developer Mode/symlink setting (requires administrator); enable Developer Mode
and run `flutter build windows --debug`. See `docs/CLIENTS.md`.

## What is intentionally disabled

- Password login (needs Argon2id verifier from Rust).
- Names/content decryption (needs XChaCha20-Poly1305 + keyfile unlock).
- Upload/download (needs chunking, encryption, erasure coding, sync).
- Sync engine, virtual drive, photo backup, DocumentsProvider/File Provider.

## Run

```bash
cd clients/flutter
flutter pub get
flutter run -d linux        # or -d windows / a connected Android device
```

Platform runners are committed for Linux, Android and Windows. For iOS:

```bash
flutter create --platforms=ios .
flutter build ios --no-codesign
```

A working product still requires the Rust↔Dart bridge described above.

