# Containerized development checks

Linux/WSL requires Docker Engine + Compose v2+, Bash, `flock`, and access to the
Docker socket. The fast wrapper tests (`python3 scripts/test-dev-check.py`)
additionally require Python 3 with its Unix `fcntl` module: run them on Linux
or inside WSL, not native Windows Python. No third-party Python packages are
required. No host Rust, Flutter, PostgreSQL or provider credentials needed.
Docker access is privileged: use only with trusted checkout code.

```bash
bash scripts/dev-check.sh build       # once; reusable local images + PostgreSQL
bash scripts/dev-check.sh versions
bash scripts/dev-check.sh all         # fetch, fmt/check/clippy/tests, FFI, analyze/test
# Or affected suites:
bash scripts/dev-check.sh rust
bash scripts/dev-check.sh flutter
```

CI remains authoritative and uses rolling Rust stable. These local images are a
reviewed snapshot: Ubuntu **24.04** and PostgreSQL **16-alpine** are pinned by
registry digest in the Dockerfile/Compose; Rust **1.99.1** includes rustfmt and
clippy; Flutter **3.47.9 / Dart 3.13.7** uses the official archive's SHA-256.
`versions` records the actual SDK versions. Refresh pins deliberately and rebuild;
normal checks never rebuild or update SDKs. Apt dependencies and the rustup
installer are fetched from live repositories, not snapshot/checksum-pinned, so
this is not a bit-for-bit reproducible image build. These are Linux amd64
checks, not Android/iOS/Windows release builders. Flutter tests load a real
`cargo build --release -p nntdrive-ffi` library directly from the target cache.

## Why a separate Compose file?

`deploy/docker-compose.dev.yml` is an override for the running evaluation app:
it reuses the deployment backend/database and adds mock NNTP. We retain that
existing workflow unchanged. `deploy/docker-compose.checks.yml` is intentionally
standalone: extending the deployment services would inherit `.env`, persistent
application data and published ports. Tests already start in-process mock NNTP
servers; a second mock/backend service would duplicate them. Never combine the
checks file with deployment Compose files.

## Isolation, concurrency, resources

- Project name is a SHA-256-derived hash of the physical checkout path. Separate
  Git worktrees have separate containers, internal networks, caches and outputs.
- `.toolchain/` (ignored) retains Cargo registry/git cache, pub cache, home and
  Rust target artifacts **per worktree**. Flutter's generated build/.dart_tool
  outputs stay in that worktree. Do not share this directory across worktrees.
- An exclusive nonblocking `flock` spans the entire wrapper, including cleanup;
  overlapping calls in one worktree exit 75 instead of corrupting caches. Use
  separate worktrees for concurrency; do not bypass the wrapper.
- Tools run as the invoking UID/GID, so generated files are not unexpectedly
  root-owned. Do not switch users against the same cache. Source is writable
  because Flutter generates files; review `git status` after checks.
- Dependency fetch containers have outbound network access, but no deployment
  env file or host credentials. Check containers use an **internal-only** Docker
  network, with no external provider access. Rust checks use `--offline --locked`;
  Flutter uses `--no-pub`. No Docker socket or host home is mounted.
- Each tool container: 2 CPUs, 6 GiB RAM, 512 PIDs; Cargo jobs=2, incremental
  disabled and debug/test symbols disabled to bound disk. Release FFI settings
  otherwise follow the workspace. BuildKit image builds are not covered by those
  runtime limits; build once during setup, not every scheduled run.
- PostgreSQL: 1 CPU, 768 MiB RAM, 128 PIDs, 512 MiB tmpfs; no ports published,
  no persistent DB volume, no restart policy. Health and a real SQL query are
  required before tests, preventing silent missing-database skips. The public
  test-only credentials match CI, not any deployment credentials.
- Every invocation traps exit and tears down **only its own** Compose project.
  `run --rm` removes checks; DB tmpfs disappears on cleanup. SIGKILL/host failure
  cannot run traps; recover using the same project name printed by Compose and
  this checks file, never global Docker prune commands. Caches survive cleanup.

Budget at least 16 GiB free disk before the first build (SDK image layers,
unpacked snapshots and Cargo artifacts all consume space). The wrapper refuses
builds below 10 GiB free, a cold worktree below 4 GiB, and warm checks below
2 GiB; these are minimum admission guards, not guarantees of peak use. Monitor
`df -h`, `docker system df`, and `du -sh .toolchain`. Never automatically prune
unrelated images/volumes or delete caches. Ask before removing this worktree's
caches.

## Verification (2026-11-05)

The counts below are the earlier pinned-container verification snapshot. They
precede the later NNT-016 snapshot and post-NNT-017 integrated suite; see
`docs/STATUS.md` for the dated totals and latest exact-head app test count.

`bash scripts/dev-check.sh build` and `bash scripts/dev-check.sh all` exited 0;
a second warm-cache `all` also exited 0. Actual tool versions: Rust/Cargo 1.99.1,
Flutter 3.47.9, Dart 3.13.7, PostgreSQL 16.15. Formatting, workspace check,
clippy with `-D warnings`, all **86 Rust tests** (no database skips), release
FFI build, Flutter analyze (no issues), and all **6 Flutter tests** passed.
The Flutter suite included native bridge, updater and widget tests.

Live Docker inspection verified internal-only check networking, no published DB
ports, the PostgreSQL tmpfs and configured CPU/RAM limits. Overlapping wrapper
execution exited 75. Cleanup removed project containers/networks and retained
caches; no deployment services, schedules or provider settings were changed.

An initial layered Flutter SDK build exhausted disk during image export. Fixed
by combining extraction/permissions/pruning into one layer and removing unused
Android/web artifacts. Only the failed toolchain image and its exact build-cache
records were cleaned up; no global prune was used. Additional disk capacity was
provisioned before publication. Continue checking headroom before cold builds.
Review fixes rebuilt both pinned image targets and reran the entire `all` command
twice as non-root UID/GID **10001:10001** in a separate writable workspace with
its own copied caches (never sharing/chowning the original cache). The second run
used a fresh HOME. Both runs passed **86 Rust / 6 Flutter** tests, formatting,
check, clippy, release FFI build and analysis; no PostgreSQL skips. Programmatic
ownership inspection found no workspace/cache entries owned by another UID.
The wrapper now configures Flutter in each worktree HOME before pub get; fresh
HOME settings confirmed `enable-linux-desktop: true`. Build-time Flutter config
alone is insufficient because the runtime HOME differs. Non-root Docker access
requires socket group membership and a writable host HOME; retaining root's HOME
initially prevented Docker CLI configuration/plugin discovery, before any checks
ran. Retrying with a dedicated HOME passed. Cleanup left no project containers or
networks.

All three original root-run logs were parsed independently: each contains 86 Rust
and 6 Flutter passes (the suggested reviewer total of 82 was not reproduced).
`bash -n scripts/dev-check.sh`, `git diff --check` and
`python3 scripts/test-dev-check.py` passed (4 wrapper/Compose contracts).
CI wiring is now implemented under NNT-020 (#5); the normal authorized main push
succeeded with the current token. Four wrapper contracts and the fail-closed DB
gate run automatically, and the pinned container suite has an explicit manual
workflow. See [CI coverage](CI.md) for contracts and limitations; inspect exact
run results before claiming hosted-container success.

The first manual hosted run correctly rejected 14 GiB free disk; its workflow
now removes unused Android/.NET SDKs only from its disposable GitHub runner.
The next run exposed a fresh-image non-root Flutter write failure at
`/opt/flutter/packages/flutter_tools/.dart_tool/version` (also reproduced locally
as UID/GID 10001:10001). The Dockerfile grants runtime writes to that generated
tool directory as well as `bin/cache`, in the SDK extraction layer. Do not infer
fresh-image non-root compatibility from a root-run or a previously warmed SDK.

## Agent-neutral worker startup

All coding workers (Codex, OpenCode, Hermes, or another tool) read the root
`AGENTS.md` as their common entry point. Do **not** replicate task selection,
merge, issue-closure, or security rules in scheduler-specific prompts. The
worker runtime retains only its model, workdir, scheduling, identity, access and
permissions. For scheduled autonomous runs, a sufficient launcher instruction is:

> Follow `AGENTS.md` and referenced documents. Recover your own unfinished work;
> otherwise perform one eligible GitHub issue and leave a verified handoff.

This does not create a new scheduler. Follow the concurrency/fail-closed rule in
`AGENTS.md`: comments and Project fields are not atomic claims; until a tested
claiming mechanism is implemented and adopted by every worker, use a dispatcher
for allocating new tasks to competing agents.

A new worktree needs its own dependency fetch/target cache (performed by the
wrapper). If the toolchain image is missing, `bash scripts/dev-check.sh build` is
the approved one-time provisioning step. The wrapper may also build a missing
image during the first check; let it finish and rerun the checks. Reuse the
image afterwards and rebuild only when the Dockerfile or pinned toolchains
change. Missing images are not a task blocker unless the build fails or disk
headroom is insufficient.
