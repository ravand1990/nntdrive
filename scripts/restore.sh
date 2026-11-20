#!/usr/bin/env bash
# Restores a backup created by scripts/backup.sh.
#
# Usage: scripts/restore.sh <backup-directory> --yes
# The stack should be stopped except PostgreSQL. This is destructive: it drops
# and recreates the nntdrive database.
#
# Database target, in precedence order:
#   USE_LOCAL_PG=1 and DATABASE_URL   pg_restore against any reachable server
#   PG_CONTAINER=<container>          psql/pg_restore inside an existing PostgreSQL container
#   default                           the deploy compose stack (stops/starts the backend)
# PG_USER/PG_DB/PG_ADMIN_DB select the role, database and maintenance database
# for PG_CONTAINER mode (defaults nntdrive/nntdrive/postgres).
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
container="${PG_CONTAINER:-}"
pg_user="${PG_USER:-nntdrive}"
pg_db="${PG_DB:-nntdrive}"
pg_admin_db="${PG_ADMIN_DB:-postgres}"

if [[ "${USE_LOCAL_PG:-0}" == "1" && -n "$container" ]]; then
  echo "set either USE_LOCAL_PG=1 or PG_CONTAINER, not both" >&2
  exit 2
fi

echo "This will DROP the current nntdrive database and restore $src."
read -r -p "Type RESTORE to continue: " confirm
[[ "$confirm" == "RESTORE" ]] || { echo "aborted"; exit 1; }

if [[ "${USE_LOCAL_PG:-0}" == "1" ]]; then
  : "${DATABASE_URL:?DATABASE_URL is required with USE_LOCAL_PG=1}"
  pg_restore --clean --if-exists --no-owner --no-privileges --dbname="$DATABASE_URL" "$src/nntdrive.dump"
elif [[ -n "$container" ]]; then
  docker inspect "$container" >/dev/null 2>&1 \
    || { echo "no such container: $container" >&2; exit 1; }
  docker exec -i "$container" \
    psql -U "$pg_user" -d "$pg_admin_db" -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"$pg_db\" WITH (FORCE);"
  docker exec -i "$container" \
    psql -U "$pg_user" -d "$pg_admin_db" -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"$pg_db\" OWNER \"$pg_user\";"
  docker exec -i "$container" \
    pg_restore -U "$pg_user" -d "$pg_db" --no-owner --no-privileges < "$src/nntdrive.dump"
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
