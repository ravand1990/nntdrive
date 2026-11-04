# Changelog

All notable changes are documented here. Every release tag **must** have an
entry with `### Features` and/or `### Bug fixes` (at least one bullet). The
release workflow refuses to publish if the entry is missing.

## [Unreleased]

### Features

- Sync now streams file content through the HTTP remote adapter instead of buffering whole files in memory, making large-file sync practical.
- Remote content hashes are cached locally, enabling remote file-rename detection and same-content convergence.

### Bug fixes

- Sync folder removal now also deletes the remote-hash cache.

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
