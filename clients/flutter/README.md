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

## What is intentionally disabled

- Password login (needs Argon2id verifier from Rust).
- Names/content decryption (needs XChaCha20-Poly1305 + keyfile unlock).
- Upload/download (needs chunking, encryption, erasure coding, sync).
- Sync engine, virtual drive, photo backup, DocumentsProvider/File Provider.

## Run (once Flutter is installed)

```bash
cd clients/flutter
flutter create --platforms=android,ios,linux,windows .
flutter pub get
flutter run -d linux   # or windows/chrome for UI checks
```

`flutter create` adds the platform runners that are not committed in this
scaffold (their generated files depend on the Flutter SDK version and would be
misleading without a build). The CI client workflow is non-blocking until the
bridge lands.
