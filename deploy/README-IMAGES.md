# Running NNTDrive without cloning the repository

The canonical no-clone instructions, including the complete
`docker-compose.yml` snippet and `.env` block, are in the main
[`README.md`](../README.md). Use those snippets directly; this document covers
operational details around them.

Edit `.env`:

```bash
# strong database password
POSTGRES_PASSWORD=$(openssl rand -hex 24)

# 32 bytes, base64; encrypts provider passwords at rest
NNTDRIVE_SECRET_KEY=$(openssl rand -base64 32)

# pin the image version (recommended)
NNTDRIVE_VERSION=0.4.0
```

On PowerShell:

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
