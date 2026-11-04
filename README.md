# NNTDrive

Self-hosted, end-to-end encrypted cloud storage that uses **Usenet as its primary
remote storage medium**. It gives you a Google Drive-like workflow — chunked,
deduplicated uploads, immutable versions, bidirectional sync, version history,
conflict preservation, self-healing erasure-coded storage — without keeping a
permanent plaintext or ciphertext copy of your library on the server.

> **Project status.** The storage engine, self-healing layer, backend and the
> Linux/Android/Windows Flutter clients are working end-to-end: register/login,
> browse, upload, download, verify, versions, delete, favorites and
> **multi-folder bidirectional sync** (base + additional folders, automatic every
> 5 minutes, conflict copies) are implemented and verified. Not finished: iOS
> builds, virtual drives, native mobile document providers/photo backup, and
> sharing UIs.

## What works today (verified by automated tests)

| Area | Status |
|---|---|
| XChaCha20-Poly1305 E2EE, Argon2id, HKDF, per-chunk keys | ✅ tested |
| Password keyfile, offline recovery kit, device wrapping (X25519), epoch rotation | ✅ tested |
| Streaming FastCDC chunking, zstd, dedupe by encrypted chunk reuse | ✅ tested |
| Reed–Solomon erasure coding (default 30 %), shard reconstruction | ✅ tested |
| Real NNTP/TLS client, pooling, retries, yEnc, NZB, STAT/BODY/POST | ✅ tested against a mock server |
| Upload → post → read-back verification → commit | ✅ tested |
| Article loss, corruption, provider outage, retention expiry simulation | ✅ tested |
| Stripe repair and retention refresh with read-back verification | ✅ tested (real PostgreSQL + mock NNTP) |
| Immutable versions, manifest encryption, version history | ✅ tested |
| Three-way sync reconciliation, conflict copies, renames, case collisions | ✅ tested |
| Multi-tenant Axum API, device tokens, revocation, admin endpoints, SSE | ✅ tested |
| PostgreSQL schema, migrations, durable jobs, admin dashboard | ✅ tested |
| Dockerfile, Compose, backup/restore scripts, CI | ✅ provided (image build in CI) |
| Flutter desktop/mobile client | ✅ Linux/Android/Windows builds; browse/upload/download + multi-folder sync verified |
| iOS build/signing | ❌ needs macOS/Xcode |
| Virtual drives / mobile document providers | ❌ not implemented |

## Quick start: the storage demo (no Usenet account needed)

Requirements: Rust (stable), PostgreSQL 14+ reachable via `DATABASE_URL`, and
Linux/macOS/WSL. The demo starts an in-process NNTP server and simulates data
loss.

```bash
export DATABASE_URL=postgres://postgres:postgres@localhost/nntdrive
cargo run -p nntdrive-cli -- demo --keyfile-out /tmp/nntdrive-demo.keyfile.json
```

It performs: encrypted upload → download and byte-for-byte verification →
one-article-per-stripe loss → erasure reconstruction → repair and re-verification
→ deduplicated re-upload → whole-stripe loss reported as **unrecoverable**
(never as a false success). The recovery kit and recovery code are printed; the
code is shown exactly once.

See the sample output in [docs/STATUS.md](docs/STATUS.md). The HTTP API is
documented in [docs/API.md](docs/API.md).

## Quick start: Docker Compose backend

```bash
cp deploy/.env.example deploy/.env
# edit deploy/.env: POSTGRES_PASSWORD, NNTDRIVE_SECRET_KEY
openssl rand -base64 32     # value for NNTDRIVE_SECRET_KEY

docker compose -f deploy/docker-compose.yml up -d --build
curl -fsS http://127.0.0.1:8080/healthz
```

Create the first (administrator) account and an operator token:

```bash
docker compose -f deploy/docker-compose.yml exec backend \
  nntdrive --database-url "$DATABASE_URL" account-create --email you@example.com \
  --password 'a long passphrase' --keyfile-out /tmp/you.keyfile.json

docker compose -f deploy/docker-compose.yml cp \
  backend:/tmp/you.keyfile.json ./you.keyfile.json

docker compose -f deploy/docker-compose.yml exec backend \
  nntdrive --database-url "$DATABASE_URL" token-create --account <account-id> --label admin
```

Then open `http://127.0.0.1:8080/admin`, paste the token, and configure an NNTP
provider. Provider changes apply after `docker compose restart backend`.

**Store the recovery code and keyfile offline before uploading anything.** The
server cannot recover E2EE data without them. See
[docs/DISASTER_RECOVERY.md](docs/DISASTER_RECOVERY.md).

For a public deployment, enable the Caddy profile (`--profile tls`) and set
`NNTDRIVE_DOMAIN`. Caddy obtains and renews TLS certificates automatically.

## Run from the published image (no repository checkout)

Backend images are published to GHCR by `.github/workflows/release.yml`:

```
ghcr.io/ravand1990/nntdrive-backend:<version>   # e.g. 0.1.0
ghcr.io/ravand1990/nntdrive-backend:latest
ghcr.io/ravand1990/nntdrive-backend:edge        # main branch
```

The package is currently private because the repository is private. Authenticate
with a GitHub token that has `read:packages`:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u ravand1990 --password-stdin
```

Create a directory:

```bash
mkdir nntdrive && cd nntdrive
```

Save the following as `docker-compose.yml`, and save the environment block as
`.env` beside it. No repository checkout is needed.

```yaml
name: nntdrive

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_DB: nntdrive
      POSTGRES_USER: nntdrive
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}
    volumes:
      - nntdrive-pg:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nntdrive -d nntdrive"]
      interval: 10s
      timeout: 5s
      retries: 10
    expose:
      - "5432"

  backend:
    image: "${NNTDRIVE_IMAGE:-ghcr.io/ravand1990/nntdrive-backend}:${NNTDRIVE_VERSION:-latest}"
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    env_file:
      - .env
    environment:
      DATABASE_URL: postgres://nntdrive:${POSTGRES_PASSWORD}@postgres:5432/nntdrive
      NNTDRIVE_BIND: 0.0.0.0:8080
      NNTDRIVE_CACHE_DIR: /var/lib/nntdrive/cache
    volumes:
      - nntdrive-cache:/var/lib/nntdrive/cache
    ports:
      - "${NNTDRIVE_HOST_BIND:-127.0.0.1}:${NNTDRIVE_HOST_PORT:-8080}:8080"
    security_opt:
      - no-new-privileges:true

  caddy:
    image: caddy:2-alpine
    profiles: ["tls"]
    restart: unless-stopped
    depends_on:
      - backend
    command:
      - caddy
      - reverse-proxy
      - --from
      - "${NNTDRIVE_DOMAIN:?set NNTDRIVE_DOMAIN}"
      - --to
      - backend:8080
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - caddy-data:/data
      - caddy-config:/config

volumes:
  nntdrive-pg:
  nntdrive-cache:
  caddy-data:
  caddy-config:
```

`.env` (set a random `POSTGRES_PASSWORD`, a base64 32-byte
`NNTDRIVE_SECRET_KEY`, and pin a version):

```dotenv
POSTGRES_PASSWORD=change-me-to-a-long-random-value
NNTDRIVE_SECRET_KEY=

NNTDRIVE_IMAGE=ghcr.io/ravand1990/nntdrive-backend
NNTDRIVE_VERSION=0.1.0
NNTDRIVE_HOST_BIND=127.0.0.1
NNTDRIVE_HOST_PORT=8080

# Only used by the "tls" profile.
NNTDRIVE_DOMAIN=drive.example.com

RUST_LOG=info,sqlx=warn
LOG_FORMAT=json
```

Generate the secret with `openssl rand -base64 32` (PowerShell:
`[Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 }))`),
then start:

```bash
docker compose up -d
curl -fsS http://127.0.0.1:8080/healthz
```

Open `http://127.0.0.1:8080/`: a fresh backend offers first-time setup. Add
providers in `/admin`, then **Maintenance → Restart backend**. For automatic TLS:

```bash
docker compose --profile tls up -d
```

Details, upgrades and backups: [deploy/README-IMAGES.md](deploy/README-IMAGES.md).

**Releasing a new version:** update `CHANGELOG.md` with a `## [x.y.z]` section
containing `### Features` and/or `### Bug fixes`, bump the workspace version in
`Cargo.toml`, commit, then push a matching semver tag. CI validates the changelog
entry, tests the workspace, builds and pushes the `linux/amd64` image, and creates
a GitHub release whose notes are generated from that section.

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Run the full app without a Usenet account (dev stack)

The dev override adds an in-memory NNTP provider and enables open registration,
so you can exercise the complete encrypted flow locally:

```bash
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.dev.yml up -d --build
bash scripts/build-clients.sh
```

- **Linux:** run `clients/flutter/build/linux/x64/release/bundle/nntdrive`.
- **Windows:** enable Developer Mode, build the DLL
  (`cargo build --release -p nntdrive-ffi`), copy
  `target\release\nntdrive_ffi.dll` to `clients\flutter\windows\runner\`, then
  `cd clients\flutter; flutter build windows --release` and run
  `build\windows\x64\runner\Release\nntdrive.exe`.
- **Android:** install `clients/flutter/build/app/outputs/flutter-apk/app-release.apk`.

In the app use server `http://127.0.0.1:8080` (or your machine's LAN IP for a
phone). A fresh backend is detected automatically: the app shows **First-time
setup**, creates the first administrator locally, and presents the one-time
recovery code and admin API token. Later registrations appear only if
`NNTDRIVE_ALLOW_REGISTRATION=true`; otherwise use **Sign in**.

Prefer a terminal bootstrap? One command creates the first admin, keyfile,
recovery kit and admin token:
```bash
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.dev.yml up -d
scripts/bootstrap.sh you@example.com
```

It prints the credentials once and copies the keyfile/recovery kit to
`bootstrap-credentials/` (git-ignored).

A headless verification of the same client path is available:

```bash
cargo run -p nntdrive-client --example smoke -- http://127.0.0.1:8080 /tmp/somefile
```

For a real deployment replace the dev override with `NNTDRIVE_NNTP_PROVIDERS`
pointing at a posting-enabled provider (Eweka example in
`deploy/providers.example.json`).

## Folder sync

Open the sync icon (⟳) in the file browser:

1. **Select base folder** — e.g. `C:\Users\you\NNTDrive` or `~/NNTDrive`.
2. Add **additional folders** for anything else you want mirrored.
3. Sync runs automatically every 5 minutes while the app is open; use **Sync all
   now** or per-folder **Sync now** for immediate runs. Pause is available.
4. Concurrent edits on two devices produce conflict copies
   (`name (conflict device timestamp).ext`); nothing is overwritten.

The same encrypted remote tree is used by the browser and sync. Local files stay
plaintext on disk (use BitLocker/LUKS/FileVault if that matters); everything sent
to the backend/Usenet is encrypted per chunk with filenames sealed.

## Eweka / first provider

Posting must be enabled on your provider account, and the provider's terms must
allow this usage. Copy `deploy/providers.example.json`, fill in Eweka
credentials, and either set `NNTDRIVE_NNTP_PROVIDERS` or add the provider in the
admin dashboard. Separate posting and retrieval providers are supported
(`role: posting_only` / `retrieval_only`).

Retention is a provider promise, not a guarantee. NNTDrive treats it as a hint:
it schedules refreshes with a configurable safety margin and reports degraded or
unrecoverable data instead of pretending retention is unlimited.

## Architecture in one screen

```text
Desktop / mobile client (Rust core + Flutter UI)
  chunk → compress → encrypt → erasure-code → HTTP (ciphertext only)
        │                                           │
        │                                           ▼
        │                                  Axum backend (Linux)
        │                                  auth, devices, PostgreSQL,
        │                                  cache, jobs, admin API
        │                                           │
        │                                           ▼
        │                                  NNTP/TLS pool (yEnc, NZB)
        │                                           │
        └────────── direct article fetch ───────────┤
                                                    ▼
                                           Usenet provider(s)
```

The backend never receives plaintext or an account master key. Clients upload
**already encrypted** chunks; the backend adds Reed–Solomon parity and posts
articles, then verifies them. Downloads can fetch shards directly from Usenet or
through the backend's authenticated article proxy/cache.

## Repository layout

```
crates/crypto/    key hierarchy, envelopes, device wrapping, recovery kits
crates/nntp/      NNTP/TLS client, pool, yEnc, NZB, fault-injecting mock server
crates/storage/   chunking, erasure coding, manifests, upload/download/repair
crates/sync/      scanner, SQLite journal, three-way reconciliation
crates/backend/   Axum API, auth, admin, jobs, embedded admin dashboard
crates/cli/       operator CLI + end-to-end storage demo
migrations/       PostgreSQL schema
deploy/           Dockerfile, Compose, Caddyfile, env examples
scripts/          backup and restore
clients/flutter/  Flutter client (Rust FFI core, Linux/Android UI)
docs/             architecture, security, operations, recovery, status
```

## Development

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets
cargo test --workspace --all-targets   # needs PostgreSQL, see docs/DEVELOPMENT.md
```

The tests spin up a real PostgreSQL schema per test and an in-process NNTP
server. They never touch a real provider.

## Security summary

- Content: XChaCha20-Poly1305, random 192-bit nonces, per-chunk HKDF keys bound
  to account, chunk hash, length and codec; no convergent encryption.
- Names and manifests: client-sealed envelopes; the server stores opaque bytes.
- Password: Argon2id (64 MiB, t=3); the server receives a separate Argon2id
  verifier, never the password or master key.
- Devices: X25519-wrapped AMK; revocation requires master-key rotation (the
  removed device cannot read content encrypted after rotation, but content it
  could already read remains readable to it — an inherent property of E2EE).
- Provider credentials: encrypted at rest with `NNTDRIVE_SECRET_KEY`; a fully
  compromised backend host can still use them to post/read ciphertext.
- Logical deletion is not physical deletion; Usenet articles generally cannot be
  deleted reliably. See [docs/SECURITY.md](docs/SECURITY.md) and
  [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## License

AGPL-3.0-or-later. See `LICENSE`.
