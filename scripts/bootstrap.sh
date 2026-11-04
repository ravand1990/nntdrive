#!/usr/bin/env bash
# One-command first-run bootstrap:
#   - starts/uses the Docker Compose stack
#   - creates the first administrator account (keyfile + recovery kit)
#   - mints an admin dashboard token
#   - copies the credentials to ./bootstrap-credentials/ and prints them once
#
# Usage:
#   scripts/bootstrap.sh you@example.com
#   NNTDRIVE_PASSWORD='...' scripts/bootstrap.sh you@example.com
#
# Set NNTDRIVE_PROD=1 to use the production Compose file (no mock NNTP).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
email="${1:-}"
if [[ -z "$email" ]]; then
  echo "usage: $0 <email>" >&2
  exit 2
fi
if ! [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo "invalid email address" >&2
  exit 2
fi

password="${NNTDRIVE_PASSWORD:-}"
if [[ -z "$password" ]]; then
  read -r -s -p "Password for $email (min 8 chars): " password
  echo
  read -r -s -p "Repeat password: " password2
  echo
  [[ "$password" == "$password2" ]] || { echo "passwords do not match" >&2; exit 1; }
fi
if [[ ${#password} -lt 8 ]]; then
  echo "password must be at least 8 characters" >&2
  exit 1
fi

compose=(docker compose -f "$root/deploy/docker-compose.yml")
if [[ "${NNTDRIVE_PROD:-0}" != "1" ]]; then
  compose+=(-f "$root/deploy/docker-compose.dev.yml")
fi

echo "== starting PostgreSQL and backend =="
"${compose[@]}" up -d postgres backend

echo "== waiting for the database =="
for _ in $(seq 1 60); do
  if "${compose[@]}" exec -T postgres psql -U nntdrive -d nntdrive -tAc \
      "SELECT count(*) FROM accounts" >/tmp/nntdrive_accounts 2>/dev/null; then
    break
  fi
  sleep 2
done
count="$(tr -d '[:space:]' < /tmp/nntdrive_accounts 2>/dev/null || echo '')"
if [[ -z "$count" ]]; then
  echo "database did not become ready" >&2
  exit 1
fi
if [[ "$count" != "0" ]]; then
  echo "this server already has $count account(s); first-run setup is disabled." >&2
  echo "Use the app, or scripts/mint-admin-token.sh for an existing account." >&2
  exit 1
fi

mkdir -p "$root/bootstrap-credentials"
chmod 700 "$root/bootstrap-credentials"
remote_dir="/var/lib/nntdrive/bootstrap"
"${compose[@]}" exec -T backend mkdir -p "$remote_dir"

echo "== creating the first administrator =="
"${compose[@]}" exec -T -e NNTDRIVE_PASSWORD="$password" backend \
  nntdrive bootstrap \
  --email "$email" \
  --keyfile-out "$remote_dir/admin.keyfile.json" \
  --recovery-out "$remote_dir/admin.recovery.json" \
  | tee "$root/bootstrap-credentials/setup.txt"

"${compose[@]}" cp "backend:$remote_dir/admin.keyfile.json" "$root/bootstrap-credentials/admin.keyfile.json"
"${compose[@]}" cp "backend:$remote_dir/admin.recovery.json" "$root/bootstrap-credentials/admin.recovery.json"
"${compose[@]}" exec -T backend rm -rf "$remote_dir"
chmod 600 "$root/bootstrap-credentials/"*

echo
echo "Credentials copied to: $root/bootstrap-credentials/"
echo "Keep that directory (and the recovery code) offline; it is git-ignored."
