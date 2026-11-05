# AGENTS.md — shared working rules

This file is for OpenCode, Codex, Hermes, and human maintainers. Read it, then the
GitHub Issues for the repository, before starting work. GitHub Issues own task
requirements, status, priority, dependencies, and ownership; this file owns
shared rules. `TASKS.md` is only a pointer.

Detailed architecture and procedures stay in `docs/`:
`docs/GITHUB-TASK-ISSUES.md` describes the issue workflow, labels, MCP tools,
migration mapping, and cutover.

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

1. **GitHub Issues** — open tasks, claims, dependencies, and linked PRs:
   <https://github.com/ravand1990/nntdrive/issues>.
   Read `docs/GITHUB-TASK-ISSUES.md` for labels and the MCP tool workflow.
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
- `.github/ISSUE_TEMPLATE/` and `.github/pull_request_template.md` — task and PR
  structure.

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
- `gh` CLI is not installed on the current Windows host; use the GitHub MCP
  issue tools or the GitHub API/UI instead.

Do not paste machine-specific temporary paths, credentials, or helper scripts
into handoff notes. Use repository-relative paths and environment variable names.

### GitHub credentials and platform access

- Use the **same GitHub PAT** that the agent uses for GitHub MCP/repository access
  as the client's auto-update token when that credential has `Contents: Read`.
  Do not create a second updater token unless the MCP credential is OAuth-only or
  lacks repository access. Never print, commit, or paste the token; store it via
  the supported client settings or environment mechanism.
- If Windows validation is required but no Windows host is available locally,
  look for an existing configured Windows machine before declaring the task
  blocked. Inspect the user's SSH configuration (`~/.ssh/config`, or
  `%USERPROFILE%\.ssh\config`) for host aliases and confirm the remote OS before
  running checks. Do not print private keys or credentials.
- Ask the coordinator/user before using an unfamiliar machine. Report the host
  alias and results, not private network details or secrets. If no Windows host
  is available, mark the task blocked with the exact missing capability; never
  claim Windows validation from Linux.

### Containerized checks

- `bash scripts/dev-check.sh build` is an approved one-time provisioning step.
  Run it before the first check when the toolchain image is absent.
- The wrapper may build a missing image on first use. Allow that build to finish,
  then rerun the check; do not block a task merely because the image was absent
  or was built during the first invocation.
- Reuse the image and the per-worktree caches. Rebuild only when the Dockerfile
  or pinned toolchains change, or when the image is missing. Track the one-time
  build in the issue handoff.
- Stop and record a blocker only if the image build fails, disk headroom is
  insufficient, or the container environment is unsafe. Do not install SDKs on
  the host.

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

- Work only inside the claimed issue. Do not mix opportunistic refactors or
  features into it. Record unrelated findings as new GitHub issues instead
  (see below).
- A task is complete only when its acceptance criteria are met and evidence is
  recorded: commands run, results, and any manual checks. Never claim a test,
  build, release, or manual verification that was not actually run.
- Minimum checks unless the task says otherwise: formatting, clippy/analyze,
  targeted tests, full affected suite, and a build when packaging or native code
  changed. State environmental skips explicitly.
- Do not declare success from a merged commit alone. Update docs/changelog,
  confirm no secrets, and hand off remaining risks.

### Bugs and feature requests found during work

When you find a bug, missing requirement, or feature request outside the claimed
issue's acceptance criteria:

1. Do not implement it inside the current task.
2. Check open/closed issues, comments, branches, and PRs for an existing entry;
   never create a duplicate.
3. Create one issue using the task or bug template, with exactly one
   `status:backlog` label and exactly one `priority:P0`, `P1`, or `P2` label.
4. Include Outcome, Scope / exclusions, Acceptance criteria, Dependencies,
   Verification, Ownership, and Handoff / blockers in the issue body. Link
   dependency issues explicitly.
5. Priority: `P0` for security, data loss, or release blockers; `P1` if it
   belongs to the current milestone; `P2` otherwise.
6. If it blocks the current task, link the dependency and set the current issue's
   status to `status:blocked`. Do not silently widen scope.
7. For security-sensitive findings, do not put secrets, exploit details, or
   private infrastructure in the repository; notify the user/coordinator first.
8. Post the handoff/evidence on the issue before stopping.

## Ownership and Git

- Read the issue, comments, assignees, dependencies, and linked/open PRs first.
  Never take an issue already claimed or in `status:in-progress`/`status:review`
  without coordinating with the user.
- One sustained session per task where practical. If you must stop, leave the
  handoff fields described below on the issue.
- Concurrent agents use separate branches and separate checkouts/worktrees, for
  example `task/<NNT-ID>-<slug>`, never the same working tree.
- GitHub issue comments and labels are coordination, not an atomic distributed
  lock. They are also shared by multiple agents using one account. If claims
  race, stop and coordinate.
- **Require explicit user approval before** committing, pushing, tagging,
  deploying, force-pushing, moving/deleting tags, resetting data, deleting
  files, or any other destructive operation.

### Before claiming: is the task already being worked on?

Use the GitHub MCP issue tools and repository state before writing code. Replace
`<NNT-ID>` with the task ID, for example `NNT-017`.

A task is already being worked on if **any** of these is true:

- The issue has `status:in-progress` or `status:review`.
- The issue has an assignee, a claim comment, or an open linked PR.
- A local or remote branch contains the task ID.
- A commit or PR contains the task ID.
- A worktree is checked out for it.

Through MCP, list/search the issue and read its body, labels, comments,
assignees, and linked PRs. Then check Git state:

```bash
git worktree list
git branch -a --list "*<NNT-ID>*"
git ls-remote --heads origin "*<NNT-ID>*"
git log --all --oneline --grep="<NNT-ID>"
```

If `git ls-remote` is unavailable, check branches and PRs in the GitHub UI. Do
not treat a failed lookup as proof that the issue is free.

Decision:

- **`status:in-progress`/`status:review`, a claim comment, an assignee, or any
  branch/PR hit** — treat as owned. Stop and ask the coordinator/user.
- **`status:blocked`** — not actively worked on, but do not claim until the
  blocker is resolved.
- **`status:ready` with no claim and no branch/PR hit** — safe to claim.
- **Records disagree** — stop and ask; never delete, force-push, or reuse an
  unrecorded branch.
- **Unrecorded branch/worktree exists** — treat it as owned and ask.

When claiming, before implementation:

1. Add a claim comment with the worker/agent name, task branch, worktree, and
   start time.
2. Set `status:in-progress` and add the responsible GitHub account as assignee
   where appropriate. Remove `status:ready`.
3. Create or use a branch named `task/<NNT-ID>-<short-slug>`.
4. Include `<NNT-ID>` in commit and PR titles so later checks find it.
5. Read the issue back and recheck for competing claims.
6. If you are allowed to push, push the claim; otherwise tell the coordinator
   that the claim exists only in your checkout.

## Status and handoff

- **Review** when implementation and evidence are ready for acceptance: set
  `status:review`, remove other status labels, open/link the PR, and post the
  verification summary. Do not close the issue.
- **Done** only after acceptance is verified, changes are integrated, and the
  user approves: leave a closure comment with the evidence and close the issue.
  Do not keep an open status label on a closed issue.
- **Blocked**: set `status:blocked` and record the exact blocker and next action.
- Before stopping or handing off, update the issue with: owner/worker, branch and
  commit/uncommitted state, completed work, exact checks and results, remaining
  work, blockers, and the exact next step.
- Use repository-relative references so handoffs work on Windows and Linux.
- Internal agent todos are temporary steps. Do not create a second persistent
  backlog outside GitHub Issues. `TASKS.md` must remain only a pointer.
