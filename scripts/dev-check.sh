#!/usr/bin/env bash
# One lock per physical worktree protects Cargo/pub caches and generated outputs.
set -euo pipefail
export CHECKOUT
CHECKOUT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
export CHECK_STATE="$CHECKOUT/.toolchain"
export LOCAL_UID=$(id -u) LOCAL_GID=$(id -g)
mkdir -p "$CHECK_STATE"/{cargo,home,pub,target}
exec 9>"$CHECK_STATE/check.lock"
flock -n 9 || { echo 'Checks already running in this worktree' >&2; exit 75; }
project="nntdrive-check-$(printf '%s' "$CHECKOUT" | sha256sum | cut -c1-12)"
# Explicit empty env file prevents deployment credentials leaking into Compose.
compose=(docker compose --env-file /dev/null --project-name "$project" -f "$CHECKOUT/deploy/docker-compose.checks.yml")
run() { "${compose[@]}" run --rm --no-deps -T "$@"; }
cleanup() { "${compose[@]}" down --timeout 10; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Fail before consuming the host's final headroom; never prune other workloads.
case "${1:-all}" in
  build|fetch|rust|flutter|all)
    available=$(df -Pk "$CHECKOUT" | tail -n 1 | tr -s ' ' | cut -d ' ' -f4)
    minimum_gib=2
    [[ -f "$CHECK_STATE/target/.rustc_info.json" ]] || minimum_gib=4
    [[ "${1:-all}" != build ]] || minimum_gib=10
    if (( available < minimum_gib * 1024 * 1024 )); then
      echo "Less than ${minimum_gib} GiB free: provision disk space before running checks" >&2
      exit 1
    fi
    ;;
esac
rust_deps() { run rust-fetch cargo fetch --locked; }
flutter_deps() { run flutter-fetch flutter pub get; }
rust_checks() {
  "${compose[@]}" up -d --wait test-db
  run rust bash -ec '
    psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -c "SELECT version(), current_database();"
    rustc --version; cargo --version
    cargo fmt --all -- --check
    cargo check --offline --locked --workspace
    cargo clippy --offline --locked --workspace --all-targets -- -D warnings
    set -o pipefail
    cargo test --offline --locked --workspace --all-targets -- --nocapture 2>&1 | tee /state/rust-tests.log
    if grep -Fq "skipping PostgreSQL-backed test:" /state/rust-tests.log; then
      echo "A PostgreSQL-backed test skipped; refusing a false green" >&2
      exit 1
    fi
  '
}
flutter_checks() {
  run rust cargo build --offline --locked --release -p nntdrive-ffi
  run flutter bash -ec '
    flutter --version
    flutter analyze --no-pub
    flutter test --no-pub
  '
}
case "${1:-all}" in
  build) "${compose[@]}" build rust flutter; "${compose[@]}" pull test-db ;;
  versions) run rust rustc --version; run flutter flutter --version ;;
  fetch) rust_deps; flutter_deps ;;
  rust) rust_deps; rust_checks ;;
  flutter) rust_deps; flutter_deps; flutter_checks ;;
  all) rust_deps; flutter_deps; rust_checks; flutter_checks ;;
  config) "${compose[@]}" config ;;
  *) echo 'Usage: bash scripts/dev-check.sh {build|versions|fetch|rust|flutter|all|config}' >&2; exit 2 ;;
esac
