# Running NNTDrive without cloning the repository

## 1. Download the deployment files

From the [GitHub release](https://github.com/ravand1990/nntdrive/releases),
download `docker-compose.release.yml` and `env.release.example` into an empty
installation directory. Rename `env.release.example` to `.env`. No repository
checkout or local build is needed; use the published Compose file rather than
maintaining a second copy of it in this guide.

The backend image is `ghcr.io/ravand1990/nntdrive-backend`. Pin a version in
`.env` instead of using `latest` for unattended upgrades. GHCR package visibility
is separate from repository visibility: if a pull requires authentication, use
a separate token with `read:packages` (not a client updater token):

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u ravand1990 --password-stdin
```

## 2. Configure

Edit `.env`, preserving the other example settings. Generate the password and
secret with the commands below, then paste their outputs into the corresponding
fields; `.env` is not a shell script and will not execute `$(...)` expressions.
Use the hex password as generated so it is safe in the database URL. Keep this
file private, and persist the same secret across restarts/upgrades.

Generate values in a shell:

```bash
# database password (hex, safe in the database URL)
openssl rand -hex 24
# persistent 32-byte secret, base64
openssl rand -base64 32
```

Set `POSTGRES_PASSWORD` and `NNTDRIVE_SECRET_KEY` to those outputs and
`NNTDRIVE_VERSION=0.5.2` in `.env`. The example also includes the image repository,
loopback HTTP binding/port, domain and logging fields. Keep the default
`NNTDRIVE_HOST_BIND=127.0.0.1`; set `NNTDRIVE_DOMAIN` before enabling TLS.

On PowerShell, generate the base64 secret with:

```powershell
[Convert]::ToBase64String((1..32 | ForEach-Object { Get-Random -Maximum 256 }))
```

## 3. Start

```bash
docker compose --env-file .env -f docker-compose.release.yml up -d
curl -fsS http://127.0.0.1:8080/healthz
```

Open `http://127.0.0.1:8080/admin` and `http://127.0.0.1:8080/`. The app detects a
fresh backend and offers first-time setup; alternatively bootstrap from the CLI:

```bash
docker compose --env-file .env -f docker-compose.release.yml exec backend \
  nntdrive bootstrap --email you@example.com \
  --keyfile-out /var/lib/nntdrive/bootstrap/admin.keyfile.json \
  --recovery-out /var/lib/nntdrive/bootstrap/admin.recovery.json
```

The token and recovery code are printed once; copy the keyfile/recovery kit out
with `docker compose cp`.

## TLS profile

Set `NNTDRIVE_DOMAIN` and start with the TLS profile. Caddy obtains certificates
automatically:

```bash
docker compose --env-file .env -f docker-compose.release.yml --profile tls up -d
```

Point DNS at the host and open ports 80/443. Keep `NNTDRIVE_HOST_BIND=127.0.0.1`
so the raw HTTP port is not publicly reachable.

## Upgrades

```bash
# edit NNTDRIVE_VERSION in .env
docker compose --env-file .env -f docker-compose.release.yml pull
docker compose --env-file .env -f docker-compose.release.yml up -d
```

Database migrations run automatically at startup. Back up first:

```bash
docker compose --env-file .env -f docker-compose.release.yml exec -T postgres \
  pg_dump -U nntdrive -d nntdrive -Fc > nntdrive-$(date -u +%Y%m%d).dump
```

## Backups

The PostgreSQL volume (`nntdrive-pg`) and the recovery kit are the recovery
anchor. Back up the database off-host and keep the recovery kit/recovery code
separately. See `docs/DISASTER_RECOVERY.md` (repository).

## Notes

- The image contains both `nntdrive-backend` and the `nntdrive` CLI.
- The cache volume (`nntdrive-cache`) is disposable; it holds encrypted shards.
- Provider configuration is stored encrypted in PostgreSQL. Set
  `NNTDRIVE_NNTP_PROVIDERS` initially or add providers in `/admin`, then
  **Restart backend**.
- Do not use `:latest` for unattended production upgrades; pin a version.
