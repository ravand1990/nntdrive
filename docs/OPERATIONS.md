# Operations

## Deployment

### From published images (no source checkout)

Images are published to GHCR with semantic version tags:

```
ghcr.io/ravand1990/nntdrive-backend:0.9.7
ghcr.io/ravand1990/nntdrive-backend:latest
ghcr.io/ravand1990/nntdrive-backend:edge
```

If the GHCR package requires authentication (independent of repository visibility),
use a token with `read:packages`:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u ravand1990 --password-stdin
```

Download matching `docker-compose.release.yml`, `nntdrive-compose.py` and
`env.release.example` files. Releases from v0.7.0 include the launcher; use the
deployment files from the matching release (see the root README). Optionally copy the
example to `.env` and pin `NNTDRIVE_VERSION=0.9.7`; both secret fields can stay
empty. On Linux/WSL with Python 3 and Compose 2.24+:

```bash
python3 nntdrive-compose.py up
```

The launcher securely generates missing deployment credentials once, independently
honors either explicit override, and saves them in `.nntdrive-secrets/secrets.json`
(0600, containing directory 0700). `.env` is never rewritten. Use this same launcher
for `restart`, `down`, `up`, `--force-recreate up`, `pull`, `exec` and `cp` so the
saved values reach both PostgreSQL and the backend. Back up the secret directory
privately off-host; losing it with existing volumes causes a deliberate refusal,
not fresh credentials. Corrupt/insecure files or changed explicit credentials also
fail closed without overwrite. Restore the original backup, never delete state
to retry. There is no rotation or automatic migration of existing deployments.

This needs no repository checkout or local image build. The backend image remains
unchanged. Concurrency, interruption, project-identity and host-admin limits:
[image deployment guide](../deploy/README-IMAGES.md#persistence-and-fail-closed-recovery).

### Docker Compose from source (recommended for development)

```bash
cp deploy/.env.example deploy/.env
# set POSTGRES_PASSWORD and NNTDRIVE_SECRET_KEY
docker compose -f deploy/docker-compose.yml up -d --build
```

TLS: add `--profile tls` and set `NNTDRIVE_DOMAIN`. Caddy terminates TLS and
proxies to the backend. Keep the backend port bound to `127.0.0.1` when a proxy
is in front.

### Publishing a release

Tagging `vX.Y.Z` runs `.github/workflows/release.yml`:

1. validates the matching `CHANGELOG.md` section (Features/Bug fixes required);
2. runs formatting, clippy, all Rust tests and the storage demo;
3. builds a `linux/amd64` image with BuildKit (arm64 can be added with native arm runners);
4. pushes `X.Y.Z`, `X.Y`, `latest` and `sha-*` tags to GHCR with provenance/SBOM;
5. creates/updates a GitHub release whose notes come from `CHANGELOG.md`, with the
   image-only Compose files attached.

Before tagging, choose a new version; **0.4.2 below is an example, not a
published release**. Do not reuse the v0.8.10 release tag.

```bash
# 1. bump the workspace version in Cargo.toml and client version in
#    clients/flutter/pubspec.yaml (including its build number)
# 2. add a section to CHANGELOG.md:
#    ## [0.4.2] - YYYY-MM-DD
#    ### Features
#    - ...
#    ### Bug fixes
#    - ...
bash scripts/release-notes.sh v0.4.2   # after adding the matching changelog entry
git tag v0.4.2
git push origin v0.4.2
```

The release workflow fails before building the image if the changelog entry is
missing, empty, or has no `Features`/`Bug fixes` bullets. `NNTDRIVE_VERSION` in
the release Compose file selects the image tag.

### Bare metal / VM

Build `nntdrive-backend`, provide PostgreSQL 14+, set env vars, and run under
systemd. Example unit:

```ini
[Unit]
Description=NNTDrive backend
After=network-online.target postgresql.service

[Service]
User=nntdrive
EnvironmentFile=/etc/nntdrive/backend.env
ExecStart=/usr/local/bin/nntdrive-backend
Restart=on-failure
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/nntdrive
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

## Configuration

| Variable | Default | Purpose |
|---|---|---|
| `DATABASE_URL` | required | PostgreSQL connection string |
| `DATABASE_MAX_CONNECTIONS` | 20 | Pool size |
| `NNTDRIVE_BIND` | `0.0.0.0:8080` | Listen address |
| `NNTDRIVE_CACHE_DIR` | `./cache` | Encrypted shard cache |
| `NNTDRIVE_CACHE_LIMIT_BYTES` | 10 GiB | Cache eviction threshold (LRU) |
| `NNTDRIVE_ALLOW_REGISTRATION` | `false` | Open sign-up (first account is admin) |
| `NNTDRIVE_SECRET_KEY` | image launcher: generated once and persisted; bare process: random per boot | Base64 32 bytes; encrypts provider passwords; supply a stable value outside the launcher |
| `NNTDRIVE_DEFAULT_QUOTA_BYTES` | unlimited | Initial per-user quota |
| `NNTDRIVE_NNTP_PROVIDERS` | — | JSON array of providers (seed if DB has none) |
| `NNTDRIVE_STORAGE_CONFIG` | defaults | JSON `StorageConfig` (redundancy, shard size, chunk sizes, verification) |
| `NNTDRIVE_HEALTH_INTERVAL_SECS` | 21600 | Health sweep cadence |
| `NNTDRIVE_REFRESH_DAYS` | 180 | Refresh articles older than this |
| `NNTDRIVE_REFRESH_INTERVAL_SECS` | 86400 | Refresh sweep cadence |
| `RUST_LOG` | `info,sqlx=warn` | Log filter |
| `LOG_FORMAT` | text | `json` for structured logs |

Defaults: Argon2id content, 30 % parity (k=10, m=3), 512 KiB shards, 1 MiB
average chunks, zstd level 3, read-back verification after posting.

## NNTP providers

Use one or more providers. `role` is `both`, `posting_only`, or `retrieval_only`;
`priority` is lower-first. Multiple posting providers are tried in order; fetch
tries all retrieval-capable providers.

```bash
cp deploy/providers.example.json /tmp/providers.json
# fill credentials, then set NNTDRIVE_NNTP_PROVIDERS="$(cat /tmp/providers.json)"
```

Or add, edit, disable or delete a provider in the admin dashboard. Passwords
remain encrypted at rest. Successful CRUD responses mean the validated pool has
been applied on the serving backend, without restarting. Each storage operation
pins one pool snapshot, including posting and verification; active operations
can finish using removed providers. New operations see the replacement pool.
Validation does not connect to the provider or prove posting permission.

The first successful admin provider mutation permanently selects DB management.
Existing provider rows also select it on upgrade. Disabling or deleting the last
provider leaves an empty pool, including after restart; environment credentials
are not silently reactivated. Add a DB provider to restore service. Invalid DB
configuration or undecryptable credentials fail closed, not back to environment.
Keep `NNTDRIVE_SECRET_KEY` stable and backed up.

Mutations use a transaction-scoped PostgreSQL advisory lock plus a process-local
publication mutex; validation precedes commit and publication precedes response.
An admitted mutation completes even if the caller disconnects. Deploy **one
backend process**: replica-wide pool invalidation is not implemented. Direct SQL
provider edits do not trigger reload; use the admin API. Connectivity failure is
not a config-validation failure; use Test before bulk transfers. Maintenance now
saves the refresh policy and displays durable per-batch results. Orphan metadata
cleanup is explicit per account (grace 1..3650 days, default UI value 7), limited
to 1000 chunks per run. First successful collection permanently requires upgraded
reference-aware clients, including when zero chunks are removed. Every retained
legacy revision must first be backfilled by an unlocked client; otherwise cleanup
reports `blocked: incomplete_version_references` without deletion or policy
change. All history/conflicts/tombstones remain protected; no NNTP article is
retracted. See [API compatibility/backfill](API.md) for the SDK flow and race
semantics. In the unlocked Flutter account menu choose **Prepare legacy references**,
then Start batch and Continue / retry until the pass reports no more incomplete
revisions. Each batch is limited to 200 revisions / 60 seconds, stops on error,
and is safe to retry; it neither enables GC nor deletes content. GC still checks
all references under its account lock. Test only on
isolated fixtures; live-stack/browser acceptance for #15 remains pending.
The Maintenance restart action remains available but is not needed for CRUD.
Configured providers have a **Test** button that verifies DNS, TLS and
authentication without posting (posting permission is only proven by a real
upload).

### Eweka

Eweka commonly uses separate hosts for reading and posting:

| Purpose | Host | Port | TLS | Role |
|---|---|---|---|---|
| Retrieval | `news.eweka.nl` | 563 | yes | `retrieval_only` |
| Posting | `post.eweka.nl` | 563 | yes | `posting_only` |

Use the same username/password for both, set a posting priority lower than the
retrieval provider, and choose a group the provider carries (e.g.
`alt.binaries.test` for a small test). Posting is only allowed if it is enabled
on your Eweka plan. A `440 posting not allowed` or `441 Posting Failed` error
comes from the provider, not from NNTDrive.

Test posting with a small demo/upload before trusting the provider with important
data.

Eweka: use `news.eweka.nl:563` with TLS. Posting must be enabled on the plan.
Retention and posting limits are contractual and can change; NNTDrive does not
assume unlimited upload or indefinite retention.

## First account and admin token

### From the app (recommended)

Open the app against a fresh backend. It calls `GET /api/v1/setup/status`, detects
that no account exists, and shows **First-time setup**. The client generates the
keyfile/recovery kit locally, registers the first account as administrator, mints
a dashboard token via `POST /api/v1/tokens`, and presents all of it once with copy
buttons. Nothing secret is sent to the server beyond the normal ciphertext and
Argon2 verifier.

### One-command CLI bootstrap

```bash
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.dev.yml up -d
scripts/bootstrap.sh you@example.com
```

It creates the first administrator (refuses if any account exists), writes the
keyfile and recovery kit into `bootstrap-credentials/`, and prints a 90-day admin
token. Set `NNTDRIVE_PROD=1` to use the production Compose file without the dev
override, or `NNTDRIVE_PASSWORD=...` for unattended use.

### Existing accounts

There is no default admin password and no pre-seeded credentials.

```bash
docker compose -f deploy/docker-compose.yml exec backend \
  nntdrive --database-url "$DATABASE_URL" account-create --email admin@example.com \
  --password 'strong passphrase' --keyfile-out /tmp/admin.keyfile.json
# copy the keyfile and recovery kit out, then delete them from the container
docker compose ... exec backend nntdrive --database-url "$DATABASE_URL" \
  token-create --account <uuid> --label admin
```

For an account that already exists (for example one created in the app), mint an
administrator token with one command:

```bash
scripts/mint-admin-token.sh you@example.com admin
```

It promotes the account to administrator, finds its UUID, and prints a token
once. Use `NNTDRIVE_PROD=1 scripts/mint-admin-token.sh ...` when the production
Compose file is running without the dev override. The token is stored hashed and
expires after 90 days; revoke it by setting `api_tokens.revoked_at`.

Open `/admin`, paste the token. The dashboard shows users, devices, storage,
Usenet volume, redundancy overhead, cache usage, article health, jobs, provider
configuration, traffic counters and recent failures. Users can be edited
(display name, quota, admin role, enabled/disabled); providers can be added,
edited, tested and deleted; health/refresh jobs can be queued. Provider changes
apply after a backend restart.

## Quotas

`accounts.quota_bytes` is enforced against the sum of distinct plaintext chunk
lengths. Deduplicated chunks count once per account. Set via the admin API or
directly in PostgreSQL. The cache has a separate limit.

## Cache

- Only encrypted shards are cached, keyed by the SHA-256 of the Message-ID.
- Eviction is oldest-file-first when the limit is exceeded.
- The cache is disposable: deleting it never loses committed data.
- Uncommitted uploads are never written to the cache (articles are cached only
  when served).
- The dashboard shows actual bytes used.

## Verifying that an upload really reached Usenet

Three independent levels:

1. **Dashboard** — Maintenance → **Verify recent articles**. The backend performs
   real NNTP `STAT` calls through the retrieval provider (not a database read)
   and reports `available/total`, the providers that have each article, and any
   missing Message-IDs.
2. **Provider check** — Usenet providers → **Test** checks DNS, TLS and
   authentication for a configured provider. It does not prove posting
   permission (only an actual upload does that).
3. **Outside NNTDrive** — fetch the article directly from the provider using its
   Message-ID. This is the strongest check because it does not trust the backend.

Get recent Message-IDs and shard hashes:

```sql
SELECT s.message_id, s.sha256, s.provider, s.posted_at, s.size
FROM shards s ORDER BY s.posted_at DESC LIMIT 10;
```

Then run the standalone checker (Python 3, no dependencies). It prompts for the
NNTP password, authenticates directly with the provider, downloads the article,
decodes yEnc, verifies its CRC and prints the SHA-256:

```powershell
python scripts\verify-article.py --user YOUR_EWEKA_USER `
  --message-id 39d1a9f51a0ab5f4.1793803145088948@nntdrive.local `
  --expect-sha256 THE_SHA256_FROM_THE_QUERY
```

Use `--host post.eweka.nl` to check the posting server instead of the default
retrieval host. If the SHA-256 matches and the provider returns the article,
the upload is genuinely on Usenet. You can also import an `.nzb` into an
independent downloader. A successful provider `STAT` proves existence only;
`BODY` + hash proves the content.

## Background jobs

- `health_sweep`: STAT all articles in batches, mark missing/corrupt, enqueue
  repairs for degraded stripes.
- `repair_stripe`: reconstruct and repost missing shards, verify read-back, then
  swap metadata atomically.
- `refresh_sweep`: repost aging stripes before retention expiry, verify, then
  swap.
- Jobs survive restart in PostgreSQL; a crash mid-job causes a retry with
  backoff. Jobs are idempotent where possible.

Watch `jobs_failed`, `missing_shards`, `corrupt_shards` and per-provider failures
on the dashboard. Alert when unrecoverable stripes appear; erasure coding cannot
fix those.

## Backups

```bash
scripts/backup.sh /secure/offhost/nntdrive-$(date -u +%Y%m%d)
```

This writes a custom-format dump, `checkpoint.json` and `SHA256SUMS`. Store the
dump off-host. The recovery kit and code must be stored **separately**. Verify
restores periodically in a staging stack.

`scripts/restore.sh <dir> --yes` restores destructively and stops the backend
first.

## Upgrades

1. Run `scripts/backup.sh`.
2. Read the release notes and the migration list.
3. `docker compose build && docker compose up -d` (migrations run at startup).
4. Check `/healthz`, the admin dashboard and a download.
5. Keep the previous image tag for rollback. Database migrations are additive in
   this release, but a downgrade may still be incompatible with newer rows.

## Scaling

- PostgreSQL is the coordination point; the job queue supports multiple backend
  replicas using `SKIP LOCKED`.
- Article fetch/post concurrency is bounded per provider; raise
  `max_connections` only within the provider's plan.
- The cache is per-backend replica and not shared.
- SSE events are read from PostgreSQL, so multiple replicas serve consistent
  cursors.

## Troubleshooting

| Symptom | Check |
|---|---|
| Uploads fail with `provider_error` | Credentials, posting permission, group, connection limits; logs redact passwords |
| `article not visible after upload` | Provider propagation delay; durability threshold may fail the chunk |
| Downloads fail as unrecoverable | Missing shards exceed parity; check health sweep output and provider retention |
| Admin login 401 | Token revoked/expired; mint a new one with `token-create` |
| 500 after upgrade | Check migration logs; DB user permissions for DDL |
| Cache grows past limit | Check `NNTDRIVE_CACHE_LIMIT_BYTES`; eviction runs on insert |
