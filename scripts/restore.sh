#!/usr/bin/env bash
# Restores a backup created by scripts/backup.sh.
#
# Usage: scripts/restore.sh <backup-directory> --yes
# The stack should be stopped except PostgreSQL. This is destructive: it drops
# and recreates the nntdrive database.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="${1:-}"
if [[ -z "$src" || "${2:-}" != "--yes" ]]; then
  echo "usage: $0 <backup-directory> --yes" >&2
  exit 2
fi
src="$(cd "$src" && pwd)"
[[ -f "$src/nntdrive.dump" ]] || { echo "missing $src/nntdrive.dump" >&2; exit 1; }
( cd "$src" && sha256sum -c SHA256SUMS )

compose="$root/deploy/docker-compose.yml"
echo "This will DROP the current nntdrive database and restore $src."
read -r -p "Type RESTORE to continue: " confirm
[[ "$confirm" == "RESTORE" ]] || { echo "aborted"; exit 1; }

if [[ "${USE_LOCAL_PG:-0}" == "1" ]]; then
  : "${DATABASE_URL:?DATABASE_URL is required with USE_LOCAL_PG=1}"
  pg_restore --clean --if-exists --no-owner --no-privileges --dbname="$DATABASE_URL" "$src/nntdrive.dump"
else
  docker compose -f "$compose" stop backend
  docker compose -f "$compose" exec -T postgres \
    psql -U nntdrive -d postgres -c "DROP DATABASE IF EXISTS nntdrive WITH (FORCE);"
  docker compose -f "$compose" exec -T postgres \
    psql -U nntdrive -d postgres -c "CREATE DATABASE nntdrive OWNER nntdrive;"
  docker compose -f "$compose" exec -T postgres \
    pg_restore -U nntdrive -d nntdrive --no-owner --no-privileges < "$src/nntdrive.dump"
  docker compose -f "$compose" start backend
fi

echo "restore complete. Verify: curl -fsS http://127.0.0.1:8080/healthz"
echo "Then run a health sweep from the admin dashboard and spot-check downloads."
