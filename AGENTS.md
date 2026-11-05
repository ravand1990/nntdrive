# AGENTS.md — shared working rules

This file is for OpenCode, Codex, Hermes, and human maintainers. Read it, then
`TASKS.md`, before starting work. `TASKS.md` owns task status; this file owns
shared rules. Detailed design stays in `docs/`.

## Project

NNTDrive is a self-hosted, end-to-end encrypted cloud storage system that uses
Usenet as primary remote storage. A Rust backend stores metadata in PostgreSQL
and posts/retrieves ciphertext articles; Flutter clients encrypt names and
content locally. The backend must never receive plaintext, plaintext filenames,
keys, or passwords.

Invariants that must not be weakened:

- Client-side encryption and chunking; use established crypto crates.
- Backend accepts ciphertext only; no server-side decrypt path.
- Conflicts preserve both versions; never last-write-wins.
- Deleting a file is logical only; posted articles cannot be physically deleted.
- Retention and provider availability are reported honestly, never assumed.
- Secrets, tokens, recovery codes, and private infrastructure details never go
  into tracked files or logs.

## Read first

1. `TASKS.md` — claim/ownership rules and current work.
2. `docs/STATUS.md` — verified capabilities, known limits, next priorities.
3. `docs/DEVELOPMENT.md` — commands, code map, conventions.
4. The task-relevant doc: `docs/ARCHITECTURE.md`, `docs/API.md`,
   `docs/CLIENTS.md`, `docs/OPERATIONS.md`, `docs/SECURITY.md`,
   `docs/DISASTER_RECOVERY.md`, or `docs/DECISIONS.md`.
5. `CHANGELOG.md` before changing user-visible behavior.

## Repository map

- `crates/crypto` — key hierarchy, envelopes, device wrapping, recovery kit.
- `crates/nntp` — TLS NNTP, pooling/retries, yEnc, NZB, articles, mock server.
- `crates/storage` — FastCDC, Reed-Solomon, manifests, upload/download, jobs.
- `crates/sync` — scanner, three-way reconcile, journal, sync engine.
- `crates/backend` — Axum API, auth, admin API/dashboard, durable jobs.
- `crates/cli` — bootstrap, account/token, demo, mock NNTP.
- `crates/client` — Rust client SDK and HTTP sync `Remote`.
- `crates/ffi` — C ABI consumed by Flutter.
- `clients/flutter` — Flutter UI, FFI bindings, sync controller, updater.
- `migrations/` — ordered SQL applied at backend startup.
- `deploy/` — Dockerfile, Compose, env examples, provider examples.
- `scripts/` — client builds, backup/restore, bootstrap, release notes.
- `.github/workflows/` — `ci.yml`, `clients.yml`, `release.yml`.

## Environment and verified commands

CI is the source of truth for release artifacts. Local builds are for the
development loop and smoke testing.

Windows development uses WSL2 Ubuntu for Rust/PostgreSQL tests; the Flutter
Windows and Android builds use the Windows Flutter SDK. CI uses
`ubuntu-24.04`, Rust stable, Flutter `3.47.9`, and PostgreSQL 16.

Verified in this workspace on 2026-11-05:

```bash
# Rust checks (WSL2, with a reachable test database)
export TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/nntdrive_test
cargo fmt --all
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --all-targets
cargo check --workspace

# Flutter (Windows SDK)
cd clients/flutter
flutter pub get
flutter analyze
flutter test test/updater_test.dart
flutter build windows --release

# Linux + Android client builds (WSL2; script encapsulates FFI + builds)
bash scripts/build-clients.sh

# Backend development stack
docker compose -f deploy/docker-compose.yml -f deploy/docker-compose.dev.yml up -d --build backend
```

Reference or CI-only commands (not re-run during the last setup pass):

- `cargo run -p nntdrive-cli -- demo --keyfile-out /tmp/nntdrive-demo.keyfile.json`
- full `flutter test` with `NNTDRIVE_FFI_PATH` set (CI and CI-built artifacts)
- `cargo fmt --all -- --check` (CI enforces it; local run may rewrite files)
- `scripts/release-notes.sh <tag>` (verified for v0.4.1 notes extraction)
- Docker image/release workflows and iOS builds (CI; iOS is non-blocking and
  unbuilt)
- `gh` CLI is not installed on the current Windows host; use the GitHub API/UI
  or Git commands instead.

Do not paste machine-specific temporary paths, credentials, or helper scripts
into handoff notes. Use repository-relative paths and environment variable names.

## Conventions

- Follow `docs/DEVELOPMENT.md`; keep encryption, sync, and NNTP transport
  separate.
- Rust 2021, workspace dependencies, `rustfmt`, and clippy with `-D warnings`.
  New SQL goes in a numbered migration; queries use runtime `sqlx::query`.
- Every account-scoped query must enforce `account_id`; add isolation tests for
  metadata changes.
- Do not hand-roll cryptography or add a plaintext fallback. Do not change the
  envelope/manifest formats without an explicit compatibility/migration plan.
- Flutter: match existing patterns and dependencies; keep long native calls off
  the UI thread; mirror FFI changes in `lib/native.dart` and test them.
- User-visible changes need a `CHANGELOG.md` entry; capability/limitation changes
  need `docs/STATUS.md`; setup changes need the relevant doc and README.
- On this Windows machine, after rebuilding the Windows client, stop the running
  `nntdrive` process and relaunch
  `clients/flutter/build/windows/x64/runner/Release/nntdrive.exe`.

## Scope and completion

- Work only inside the claimed task. Do not mix opportunistic refactors or
  features into it. Record unrelated findings in `TASKS.md` Backlog instead.
- A task is complete only when its acceptance criteria are met and evidence is
  recorded: commands run, results, and any manual checks. Never claim a test,
  build, release, or manual verification that was not actually run.
- Minimum checks unless the task says otherwise: formatting, clippy/analyze,
  targeted tests, full affected suite, and a build when packaging or native code
  changed. State environmental skips explicitly.
- Do not declare success from a merged commit alone. Update docs/changelog,
  confirm no secrets, and hand off remaining risks.

## Ownership and Git

- Read `TASKS.md` first. Claim a task by moving it to **In Progress** and
  recording owner, branch/worktree, and start date. Never take a task already
  owned by another agent or in Review without coordinating with the user.
- One sustained session per task where practical. If you must stop, leave the
  handoff fields described below.
- Concurrent agents use separate branches and separate checkouts/worktrees, for
  example `task/NNT-001-background-sync`, never the same working tree.
- Markdown is not a lock. With multiple agents, require manual assignment or a
  single coordinator; do not assume another checkout has the latest ownership.
- Edit only the relevant task in `TASKS.md`; never replace the whole file from a
  stale copy or overwrite another agent's work.
- **Require explicit user approval before** committing, pushing, tagging,
  deploying, force-pushing, moving/deleting tags, resetting data, deleting
  files, or any other destructive operation.

### Before claiming: is the task already being worked on?

Run these checks from the primary checkout **before** writing code. Replace
`<NNT-ID>` with the task ID, for example `NNT-017`.

A task is already being worked on if **any** of these is true:

- `TASKS.md` lists it under **In Progress** or **Review**, or the task entry has
  an `Owner`, `Branch`, or `Started` field.
- A local or remote branch contains the task ID.
- An open PR or a commit contains the task ID.
- A worktree is checked out for it.

```bash
git worktree list
git branch -a --list "*<NNT-ID>*"
git ls-remote --heads origin "*<NNT-ID>*"
git log --all --oneline --grep="<NNT-ID>"
# Only if the GitHub CLI is installed:
gh pr list --search "<NNT-ID>" --state open
```

If `git ls-remote` or `gh` is unavailable, check the repository's branches and
open PRs in the GitHub UI. Do not treat a failed lookup as proof that the task is
free.

Decision:

- **Any hit, or In Progress/Review in `TASKS.md`** — treat the task as owned.
  Stop and ask the coordinator/user; do not start a parallel implementation.
- **Blocked in `TASKS.md`** — not actively worked on, but do not claim it until
  the blocker is resolved.
- **Ready and no hits** — safe to claim.
- **Records disagree** — stop and ask; never delete, force-push, or reuse an
  unrecorded branch.
- **Unrecorded branch/worktree exists** — treat it as owned and ask. It may be
  stale, but that is a coordinator decision.

When claiming, before implementation:

1. Move the task to **In Progress** in `TASKS.md`.
2. Record `Owner`, `Branch/worktree`, `Started`, and `Updated` (ISO date/time).
3. Create or use a branch named `task/<NNT-ID>-<short-slug>`.
4. Include `<NNT-ID>` in commit and PR titles so later checks find it.
5. If you are allowed to push, push the claim; otherwise tell the coordinator
   that the claim exists only in your checkout.

## Status and handoff

- **Review** when implementation and evidence are ready for acceptance.
- **Done** only after acceptance is verified, changes are integrated, and the
  user approves.
- Before stopping or handing off, update the task with: owner, branch and
  commit/uncommitted state, completed work, exact checks and results, remaining
  work, blockers, and the exact next step.
- Use repository-relative references so handoffs work on Windows and Linux.
- Internal agent todos are temporary steps. Do not create a second persistent
  backlog outside `TASKS.md`.
