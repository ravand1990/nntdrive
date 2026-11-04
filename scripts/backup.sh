#!/usr/bin/env bash
# Creates a consistent PostgreSQL dump plus a recovery-anchor checkpoint.
#
# Usage: scripts/backup.sh [destination-directory]
# Requires: docker compose deploy stack running (default) or USE_LOCAL_PG=1 and
# DATABASE_URL / PG* environment variables.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${1:-$root/backups/$stamp}"
mkdir -p "$dest"
dest="$(cd "$dest" && pwd)"

compose="$root/deploy/docker-compose.yml"

if [[ "${USE_LOCAL_PG:-0}" == "1" ]]; then
  : "${DATABASE_URL:?DATABASE_URL is required with USE_LOCAL_PG=1}"
  pg_dump --format=custom --no-owner --no-privileges --file="$dest/nntdrive.dump" "$DATABASE_URL"
else
  docker compose -f "$compose" exec -T postgres \
    pg_dump -U nntdrive -d nntdrive --format=custom --no-owner --no-privileges \
    > "$dest/nntdrive.dump"
fi

dump_sha="$(sha256sum "$dest/nntdrive.dump" | awk '{print $1}')"
created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$dest/checkpoint.json" <<EOF
{
  "format": "nntdrive-checkpoint/1",
  "created_at": "$created_at",
  "database_dump": "nntdrive.dump",
  "database_dump_sha256": "$dump_sha",
  "schema_migrations": "0001_init.sql,0002_account_keys.sql",
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
