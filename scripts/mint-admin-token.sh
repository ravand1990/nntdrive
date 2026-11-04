#!/usr/bin/env bash
# Mint an operator API token for an existing account.
#
# Usage:
#   scripts/mint-admin-token.sh <email> [label]
#
# Uses the dev Compose stack (base + dev override) by default. For a production
# stack (without the mock NNTP provider) run:
#   NNTDRIVE_PROD=1 scripts/mint-admin-token.sh <email> [label]
#
# The account is promoted to administrator so the token can access /admin and
# /api/v1/admin/*. The token is printed once and stored only as a hash.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
email="${1:-}"
label="${2:-admin}"

if [[ -z "$email" ]]; then
  echo "usage: $0 <email> [label]" >&2
  exit 2
fi
if ! [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo "invalid email address" >&2
  exit 2
fi
if ! [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "label may contain only letters, digits, '-' and '_'" >&2
  exit 2
fi

compose=(docker compose -f "$root/deploy/docker-compose.yml")
if [[ "${NNTDRIVE_PROD:-0}" != "1" ]]; then
  compose+=(-f "$root/deploy/docker-compose.dev.yml")
fi

account="$("${compose[@]}" exec -T postgres \
  psql -U nntdrive -d nntdrive -tAc \
  "SELECT id FROM accounts WHERE lower(email) = lower('$email')" | tr -d '[:space:]')"

if [[ -z "$account" ]]; then
  echo "no account with email $email — create it in the app first" >&2
  exit 1
fi

"${compose[@]}" exec -T postgres psql -U nntdrive -d nntdrive -q \
  -c "UPDATE accounts SET is_admin = TRUE WHERE id = '$account';"

echo "Account $email ($account) is an administrator."
echo "Minting token (shown once):"
"${compose[@]}" exec -T backend \
  nntdrive token-create --account "$account" --label "$label"
