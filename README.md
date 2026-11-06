# NNTDrive

Self-hosted, end-to-end encrypted cloud storage with **Usenet as primary remote
storage**. Rust services manage metadata and transport ciphertext; Flutter
clients encrypt file contents and names locally. The backend has no decrypt path
and does not need a permanent copy of your library.

## Capabilities and limits

- Chunked, deduplicated uploads, immutable versions and verified downloads.
- Reed–Solomon repair and retention refresh, with explicit unrecoverable errors.
- Windows, Linux and Android clients: browse, upload/download, version history,
  multi-folder sync, selective sync and recoverable conflict choices.
- PostgreSQL metadata, an admin dashboard and container deployment.

Sync currently runs **only while the app is open**. iOS, virtual drives, native
mobile document providers/photo backup and sharing are unfinished. Windows/Linux
update support is implemented, but installed-app replacement/restart acceptance
remains open. See [verified status and limitations](docs/STATUS.md) and
[CI coverage](docs/CI.md); builds are not proof of platform runtime behavior.

Usenet retention and repair are **not durability guarantees**, and posted
articles cannot reliably be deleted. Keep off-host database backups and offline
recovery material. There has been no independent security audit.

## Quick start

### Try the storage engine without a Usenet account

With stable Rust and PostgreSQL 14+ available on Linux/macOS/WSL, set
`DATABASE_URL` to your test database and run:

```bash
cargo run -p nntdrive-cli -- demo --keyfile-out /tmp/nntdrive-demo.keyfile.json
```

The in-process NNTP demo exercises encrypted upload/download, simulated article
loss, reconstruction, repair and explicit unrecoverable loss. It prints recovery
material: keep it private. See [development setup](docs/DEVELOPMENT.md) and
[sample results](docs/STATUS.md).

### Run the backend

For a production-image install **without a repository checkout**, follow the
[published-image guide](deploy/README-IMAGES.md): download the release Compose
and environment files, set the database password and persistent secret, pin the
image version, then start with:

```bash
docker compose --env-file .env -f docker-compose.release.yml up -d
curl -fsS http://127.0.0.1:8080/healthz
```

Complete the guide's configuration steps **before** running these commands.
Use TLS for remote access. The [operations guide](docs/OPERATIONS.md) covers
first-account setup, provider configuration, upgrades and backups. Store your
recovery code and keyfile offline before uploading real data; the server cannot
recover your encrypted files without them.

For a source checkout and a mock-provider full-app walkthrough, see
[local app development](docs/DEVELOPMENT.md#local-app-with-a-mock-provider).

## Guides

| Guide | Contents |
|---|---|
| [Status](docs/STATUS.md) | Verified capabilities, evidence and known limitations |
| [Client platforms](docs/CLIENTS.md) | Builds, folder sync, updates and mobile restrictions |
| [Published images](deploy/README-IMAGES.md) | No-clone install, image authentication, TLS and upgrades |
| [Operations](docs/OPERATIONS.md) | Configuration, providers, admin, backups and troubleshooting |
| [Disaster recovery](docs/DISASTER_RECOVERY.md) | Recovery anchors, restore procedures and loss scenarios |
| [Security](docs/SECURITY.md) | Threat model, cryptography, key handling and deletion limits |
| [Architecture](docs/ARCHITECTURE.md) | Components, encrypted data flow and storage/sync design |
| [API](docs/API.md) | Client and administrator HTTP endpoints |
| [Development](docs/DEVELOPMENT.md) | Toolchains, code map, local app and test commands |
| [Container checks](docs/CONTAINER-DEVELOPMENT.md) | Isolated Rust/Flutter checks without host SDK installation |
| [CI](docs/CI.md) | Automated coverage, release gates and unverified platform behavior |
| [Changelog](CHANGELOG.md) | Version history |

Release maintainers: follow [publishing a release](docs/OPERATIONS.md#publishing-a-release)
with a new version; do not reuse an existing tag.

## License

[AGPL-3.0-or-later](LICENSE).