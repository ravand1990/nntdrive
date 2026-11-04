# NNTDrive

Self-hosted, end-to-end encrypted cloud storage that uses **Usenet as its primary
remote storage medium**. It gives you a Google Drive-like workflow — chunked,
deduplicated uploads, immutable versions, bidirectional sync, version history,
conflict preservation, self-healing erasure-coded storage — without keeping a
permanent plaintext or ciphertext copy of your library on the server.

> **Project status — read this first.** This repository is a working,
> tested storage engine, backend API and administration interface. It is **not
> yet a finished end-user product**: the Flutter client is a UI/API scaffold and
> the Rust↔Dart cryptographic bridge is not wired, so the Android/iOS/desktop
> apps do not yet perform sync. The filesystem virtual drives and native mobile
> integrations are not implemented. See [docs/STATUS.md](docs/STATUS.md) for the
> precise, verified list of what works and what does not.

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
| Flutter desktop/mobile clients | ⚠️ UI shell only; Linux/Android debug builds verified, Rust crypto/sync bridge missing |
| Virtual drives (WinFsp/FUSE) | ❌ not implemented |
| Android DocumentsProvider / iOS File Provider / photo backup | ❌ not implemented |
| Folder sharing UI, public links | ❌ API tables exist, endpoints incomplete |

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
clients/flutter/  desktop/mobile UI scaffold (see docs/CLIENTS.md)
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
