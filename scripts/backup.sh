#!/usr/bin/env bash
# Creates a consistent PostgreSQL dump plus a recovery-anchor checkpoint.
#
# Usage: scripts/backup.sh [destination-directory]
# Database source, in precedence order:
#   USE_LOCAL_PG=1 and DATABASE_URL   host pg_dump against any reachable server
#   PG_CONTAINER=<container>          pg_dump inside an existing PostgreSQL container
#   default                           the deploy compose stack's postgres service
# PG_USER/PG_DB select the role and database for PG_CONTAINER mode (defaults
# nntdrive/nntdrive).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${1:-$root/backups/$stamp}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"

compose="$root/deploy/docker-compose.yml"
container="${PG_CONTAINER:-}"
pg_user="${PG_USER:-nntdrive}"
pg_db="${PG_DB:-nntdrive}"

if [[ "${USE_LOCAL_PG:-0}" == "1" && -n "$container" ]]; then
  echo "set either USE_LOCAL_PG=1 or PG_CONTAINER, not both" >&2
  exit 2
fi

if [[ "${USE_LOCAL_PG:-0}" == "1" ]]; then
  : "${DATABASE_URL:?DATABASE_URL is required with USE_LOCAL_PG=1}"
  pg_dump --format=custom --no-owner --no-privileges --file="$dest/nntdrive.dump" "$DATABASE_URL"
elif [[ -n "$container" ]]; then
  docker inspect "$container" >/dev/null 2>&1 \
    || { echo "no such container: $container" >&2; exit 1; }
  docker exec -i "$container" \
    pg_dump -U "$pg_user" -d "$pg_db" --format=custom --no-owner --no-privileges \
    > "$dest/nntdrive.dump"
else
  docker compose -f "$compose" exec -T postgres \
    pg_dump -U nntdrive -d nntdrive --format=custom --no-owner --no-privileges \
    > "$dest/nntdrive.dump"
fi

# The checkpoint must name the migrations this repository ships, so a restore
# can be matched against a matching schema instead of a stale hand-kept list.
migrations="$(cd "$root/migrations" && printf '%s,' *.sql)"
migrations="${migrations%,}"

dump_sha="$(sha256sum "$dest/nntdrive.dump" | awk '{print $1}')"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$dest/checkpoint.json" <<EOF
{
  "format": "nntdrive-checkpoint/1",
  "created_at": "$created_at",
  "database_dump": "nntdrive.dump",
  "database_dump_sha256": "$dump_sha",
  "schema_migrations": "$migrations",
  "restore_procedure": "docs/DISASTER_RECOVERY.md",
  "notes": [
    "This dump is the authoritative metadata recovery anchor. Usenet has no globally mutable pointer.",
    "The recovery kit and recovery code must be stored separately, offline.",
    "Provider credentials in this dump are encrypted with NNTDRIVE_SECRET_KEY; without that key providers must be re-entered.",
    "Usenet articles cannot be deleted reliably; restoring an older checkpoint can resurrect logical deletions."
  ]
}
EOF
( cd "$dest" && sha256sum nntdrive.dump checkpoint.json > SHA256SUMS )

echo "backup complete: $dest"
echo "dump sha256:    $dump_sha"
echo
echo "Store $dest off the backend host, and keep the recovery kit + recovery code"
echo "somewhere else again. A backup without the recovery kit is not restorable."
