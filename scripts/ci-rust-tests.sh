#!/usr/bin/env bash
# A configured but unreachable database must never yield a green integration run.
set -euo pipefail
: "${TEST_DATABASE_URL:?CI requires a real disposable PostgreSQL database}"
psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c 'SELECT current_database(), version();'
log=$(mktemp)
trap 'rm -f "$log"' EXIT
cargo test --locked --workspace --all-targets -- --nocapture 2>&1 | tee "$log"
if grep -Fq 'skipping PostgreSQL-backed test:' "$log"; then
  echo 'A PostgreSQL-backed test skipped; refusing a false green' >&2
  exit 1
fi
