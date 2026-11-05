# TASKS.md — authoritative project plan

`TASKS.md` owns task status; `AGENTS.md` owns shared working rules. Read both
before starting. Internal agent todos are not a second backlog.

Last updated: 2026-11-05.

## Status rules

- **Backlog** — accepted requirement, not ready or not prioritized.
- **Ready** — defined, unblocked, and safe to claim.
- **In Progress** — owned by one agent; owner, branch/worktree, and start date
  recorded.
- **Review** — implementation and evidence ready; awaiting acceptance.
- **Blocked** — cannot proceed; blocker and next action recorded.
- **Done** — acceptance verified, integrated, and user-approved.

Priority is explicit on every task:

- **P0** — release, security, or user-blocking. Clear these before new feature
  work; they may still be Blocked on an external dependency.
- **P1** — current milestone (desktop sync and key handling). This is the next
  claimable work once P0 is clear.
- **P2** — planned work that waits for P0/P1 to clear.

The coordinator or user may change a priority; record the change in that task
rather than reordering the whole file.

Claim a task by moving it to In Progress and recording `Owner`, `Branch`, and
`Started`. Before claiming, run the ownership checks in `AGENTS.md`
(“Before claiming: is the task already being worked on?”). Never take an owned or
Review task without coordination. Move to Review with actual check results; move
to Done only after user approval.

Task fields: **Priority**, **Outcome**, **Scope**, **Acceptance**, **Depends on**,
**Verify**. Done entries are intentionally compact.

## Suggested order

Priority decision: **desktop sync hardening first** — it is the core workflow and
already has known gaps. Then key handling and revocation, then sharing (including
anonymous links), then mobile and platform packaging.

1. NNT-101 — confirm `v0.4.1` artifacts (unblocks release confidence).
2. NNT-102 → NNT-103 — fix the PAT, then prove a real self-update.
3. NNT-017 — check for updates on every startup.
4. NNT-004, NNT-005, NNT-001 — finish desktop sync behavior before adding
   platform surface.
5. NNT-002, NNT-003 — harden key handling and revocation.
6. NNT-008 — sharing with account recipients and anonymous links.
7. NNT-006, NNT-007, NNT-009 — platform packaging and native integrations.
8. NNT-010–NNT-018 — operational, test, and release-channel hardening as
   capacity allows.

## Decisions (2026-11-05)

- **Priority:** desktop sync hardening is the next focus. Mobile and sharing are
  not started until the desktop sync gaps are closed.
- **Repository visibility:** undecided. When releases become public, remove PAT
  support and replace it with update channels (Default/Nightly).
- **Windows signing:** no certificate at this point. Build an unsigned installer
  and clean-VM test now; add signing when a certificate exists.
- **Mobile distribution:** sideloaded APK and TestFlight-style installs are
  acceptable for now. Store distribution is deferred.
- **`linux/arm64`:** yes, build it using a GitHub native arm runner when
  available; otherwise keep the QEMU path as fallback.
- **Sharing:** both existing-account shares and anonymous public links are in
  scope.
- **Update checks:** default-on, daily, and on every app startup. Implemented as
  NNT-017; do not implement it in the task-management setup.

## Backlog

### NNT-020 — Protect container development checks against CI drift

- Priority: P2
- Outcome: wrapper contracts and container checks detect future toolchain drift.
- Scope: run `python3 scripts/test-dev-check.py` in Linux CI; add a deliberate
  manual or scheduled container-check job with documented cache/resource limits.
- Acceptance: wrapper tests run on relevant PRs; a container-check workflow can
  build the pinned images and run `bash scripts/dev-check.sh all`; failures are
  visible without starting deployment services or exposing credentials.
- Depends on: NNT-019 integration and authorization to edit workflow files.
- Verify: actual GitHub Actions runs for wrapper tests and container checks.
- Handoff: workflow wiring was deferred because GitHub rejected workflow-file
  updates under the available token permissions. Local verification is not CI
  coverage; obtain the required workflow permission before implementation.
- Owner: — · Branch: —

### NNT-001 — Background sync service

- Priority: P1
- Outcome: synchronization continues when the client UI is closed.
- Scope: desktop autostart/tray service; Android WorkManager scheduling that
  respects OS limits; status visible when the OS pauses work.
- Acceptance: desktop sync runs after closing the window and restarts on login;
  mobile scheduling is best-effort and documented; no duplicate journals.
- Depends on: none.
- Verify: `cargo test -p nntdrive-sync` plus platform smoke tests on Windows,
  Linux, and Android.
- Owner: — · Branch: —

### NNT-002 — Secure local key storage

- Priority: P1
- Outcome: the password-wrapped keyfile leaves shared preferences for OS
  credential stores.
- Scope: Windows Credential Manager, macOS/iOS Keychain, Android Keystore,
  Linux Secret Service, with migration from existing installs.
- Acceptance: unlock/recovery still work after migration; no plaintext key
  material on disk; documented fallback when no keyring is available.
- Depends on: NNT-012 for interrupted-migration tests.
- Verify: `flutter test`, native tests on each platform, manual unlock after
  upgrade.
- Owner: — · Branch: —

### NNT-003 — AMK epoch rotation on device revocation

- Priority: P1
- Outcome: revoking a device rotates the account master key and re-wraps it for
  remaining devices.
- Scope: client-side rotation, envelope/keyring updates, retain old epoch keys
  for old revisions, backend signaling only.
- Acceptance: revoked device cannot decrypt new revisions; remaining devices
  still decrypt old and new revisions; tests cover partial failure.
- Depends on: NNT-002 (key storage).
- Verify: `cargo test -p nntdrive-crypto`, backend tests, two-device client test.
- Owner: — · Branch: —

### NNT-004 — Remote folder rename as move

- Priority: P1
- Outcome: folder renames on another device propagate as local moves.
- Scope: identify folder renames without relying on path identity; preserve
  content and avoid delete+recreate; keep file-rename behavior.
- Acceptance: two-device rename test reports `moved`, not deleted/downloaded;
  no conflict copies for a clean rename.
- Depends on: none.
- Verify: `cargo test -p nntdrive-client --test sync_e2e`.
- Owner: — · Branch: —

### NNT-005 — Per-file sync progress and conflict resolution UI

- Priority: P1
- Outcome: users see per-file transfer progress and can resolve conflicts
  explicitly.
- Scope: progress events across the FFI boundary; keep-mine/keep-theirs/keep-both
  actions that never silently discard data.
- Acceptance: progress reflects real byte counts; each action produces the
  expected local and remote state; conflict copies remain recoverable.
- Depends on: none.
- Verify: sync engine tests, Flutter widget tests, two-device smoke test.
- Owner: — · Branch: —

### NNT-006 — Windows installer and clean-VM test

- Priority: P2
- Outcome: distributable Windows build and installer, with signing added when a
  certificate exists.
- Scope: installer packaging, clean VM without SDKs, make the Windows CI job
  blocking when reliable; document that the build is unsigned until a certificate
  is available.
- Acceptance: fresh Windows VM installs, launches, updates, and uninstalls with
  no DLL/path assumptions; signature validation is explicitly pending.
- Depends on: NNT-095; code-signing certificate (currently unavailable).
- Verify: Windows release build, installer smoke test, documented signature
  status.
- Owner: — · Branch: —

### NNT-007 — iOS client

- Priority: P2
- Outcome: buildable/signed iOS app with native file integration.
- Scope: Rust XCFramework, File Provider extension, BGTaskScheduler, signing.
- Acceptance: app builds on macOS, browses/decrypts, syncs within container or
  File Provider domain, and documents background limits.
- Depends on: macOS/Xcode runner and Apple signing credentials.
- Verify: `flutter build ios --no-codesign` in CI, then signed device test.
- Owner: — · Branch: —

### NNT-008 — Sharing and public links

- Priority: P2
- Outcome: folder sharing without exposing the master key, for existing accounts
  and anonymous recipients.
- Scope: per-share wrapped keys, expiring/password-protected anonymous links,
  revocation and key rotation, sharing UI.
- Acceptance: account recipients decrypt only shared content; anonymous links
  work without an account and expire; revocation prevents new access; no
  plaintext metadata leaks.
- Depends on: NNT-003.
- Verify: crypto tests, backend authorization tests, two-account client test,
  anonymous-link expiry test.
- Owner: — · Branch: —

### NNT-009 — Virtual drives and native mobile integrations

- Priority: P2
- Outcome: NNTDrive appears as a normal filesystem/provider.
- Scope: FUSE/WinFsp, Android DocumentsProvider, iOS File Provider, photo backup.
- Acceptance: mount/domain survives restart; reads/writes round-trip through the
  encrypted store; offline behavior and OS limits documented.
- Depends on: NNT-001, NNT-007.
- Verify: platform-specific manual tests plus sync tests.
- Owner: — · Branch: —

### NNT-010 — Provider/admin operations completion

- Priority: P2
- Outcome: provider changes apply without a manual restart; retention and orphan
  cleanup are operable.
- Scope: live NNTP pool reload, retention settings UI, orphaned-chunk GC with a
  grace period.
- Acceptance: edits take effect without restart; GC never deletes referenced
  chunks; admin UI shows results.
- Depends on: none.
- Verify: backend tests, storage tests, live dev-stack check.
- Owner: — · Branch: —

### NNT-011 — Security review and hardening

- Priority: P2
- Outcome: independent security pass over parsers and exposed surfaces.
- Scope: fuzz yEnc/NZB/article parsers, proxy rate-limit guidance, password-reset
  policy, audit-log coverage, dependency review.
- Acceptance: findings triaged with fixes/tasks; no high-severity issue open
  without a decision.
- Depends on: none.
- Verify: fuzz targets, dependency audit, documented review checklist.
- Owner: — · Branch: —

### NNT-012 — Test gaps

- Priority: P2
- Outcome: failures that matter in production are covered.
- Scope: interrupted upload/download, multi-GB streaming, replayed manifest,
  provider backbone correlation, restore-from-dump automation, Flutter
  integration tests that add a folder and sync.
- Acceptance: each scenario has an automated or documented repeatable test.
- Depends on: none.
- Verify: `cargo test --workspace --all-targets`, `flutter test`, restore script.
- Owner: — · Branch: —

### NNT-013 — Multi-arch container image

- Priority: P2
- Outcome: publish `linux/arm64` alongside `linux/amd64`.
- Scope: prefer a native GitHub arm64 runner (for example `ubuntu-24.04-arm`) and
  keep a QEMU fallback only if native runners are unavailable; build a multi-arch
  manifest.
- Acceptance: both architectures pull and pass `/healthz`; release notes reflect
  the multi-arch manifest; CI runtime stays reasonable.
- Depends on: GitHub arm64 runner availability for this repository/plan.
- Verify: `docker buildx imagetools inspect`, smoke test on arm64.
- Owner: — · Branch: —

### NNT-014 — Mobile update distribution (deferred decision)

- Priority: P2
- Outcome: record the current mobile distribution decision and the later store
  path.
- Scope: sideloaded APK and TestFlight-style installs are accepted for now; Play
  Store/App Store distribution is deferred until signing and release ownership
  exist.
- Acceptance: docs state the current sideload policy and the future store
  decision remains open.
- Depends on: none.
- Verify: documentation review; no code.
- Owner: — · Branch: —

### NNT-015 — Repository visibility and PAT retirement

- Priority: P2
- Outcome: decide when repository/releases become public and remove PAT support
  in favor of update channels at that point.
- Scope: PAT lifetime, scopes, rotation, removal from client settings; release
  feed policy; migration to channels (NNT-018).
- Acceptance: written decision; no PAT requirement for public releases; updater
  works from a clean install using the chosen channel.
- Depends on: user/public-visibility decision.
- Verify: release check from a clean install; settings no longer require a token.
- Owner: — · Branch: —

### NNT-016 — Documentation drift

- Priority: P2
- Outcome: docs match the actual suite and current behavior.
- Scope: reconcile the test count in `docs/STATUS.md` with real output; remove
  stale statements after releases; verify install/version examples.
- Acceptance: a fresh `cargo test --workspace --all-targets` count matches the
  docs; no stale release/version references.
- Depends on: none.
- Verify: run the suite and `git grep` for old versions/claims.
- Owner: — · Branch: —

### NNT-018 — Update channels (Default / Nightly)

- Priority: P2
- Outcome: users choose a release channel instead of using PATs.
- Scope: channel field in update settings; Default maps to stable releases,
  Nightly maps to marked prereleases/nightly tags; version comparison and asset
  selection per channel; migration from PAT settings once releases are public.
- Acceptance: Default never installs a nightly; Nightly can move forward to the
  next nightly; switching channels does not downgrade unless explicitly allowed;
  checksums/signatures apply equally.
- Depends on: NNT-015 (public releases) and NNT-095 (settings).
- Verify: publish a prerelease, check both channels from clean installs; unit
  tests for channel/tag selection.
- Open: define the nightly tag pattern, cadence, and retention policy.
- Owner: — · Branch: —

## Ready

### NNT-017 — Check for updates on every startup

- Priority: P1
- Outcome: when auto-check is enabled, each app launch checks for a newer release
  instead of waiting for the 24-hour throttle.
- Scope: startup trigger; keep the periodic daily check; skip only the prompt for
  a version the user deferred, not the check itself; prevent overlapping checks.
- Acceptance: two consecutive launches both perform a check; offline startup
  remains usable; no duplicate prompts; the auto-check setting still disables it.
- Depends on: NNT-095.
- Verify: Flutter analyze and updater tests; manual launch twice against a test
  feed and confirm network/log evidence.
- Owner: — · Branch: —

## In Progress

_None._

## Blocked — release audit

### NNT-101 — Verify v0.4.1 release artifacts and notes

- Priority: P0
- Outcome: confirm the tag produced the expected image, clients, checksums, and
  categorized release notes.
- Scope: release run, assets, SHA-256 digests, iOS non-blocking behavior.
- Acceptance: all expected assets exist; checksums match; notes contain Features
  and Bug fixes; no unexplained job failure.
- Depends on: release workflow completing.
- Verify: GitHub release page/API, download assets and compare
  `SHA256SUMS.txt`, inspect workflow jobs.
- Owner: Hermes scheduled worker
- Branch/worktree: `task/NNT-101-release-audit`; isolated task worktree.
- Started: 2026-11-05T03:11:10Z
- Updated: 2026-11-05T03:13:22Z
- Handoff: claim published as `9e38e3f`; audit evidence and this handoff are
  committed on the same branch (see branch HEAD). No product changes.
- Evidence: `docs/RELEASE-AUDIT-v0.4.1.md`; all seven assets downloaded and
  API digests matched; all three client SHA256SUMS entries matched. Release,
  Clients and CI workflows succeeded; iOS failure explained by log message
  `Application not configured for iOS` and explicit non-blocking job policy.
  Image job logs confirm versioned manifest pushes. `git diff --check` passed;
  Rust/Flutter checks not applicable to this Markdown-only release audit.
- Blocker: literal acceptance requires Features AND Bug fixes, but published
  0.4.1 notes contain Bug fixes only, accurately matching the tagged changelog.
  Existing release policy allows either category; no feature was invented.
- Next step: coordinator must accept bug-fix-only notes and explicitly adjust
  acceptance, or supply an accurate missing feature and authorize notes changes.
  Draft PR preserves evidence; no release changes, merge or deployment.

## Review

### NNT-019 — Containerized local development checks

- Priority: P1
- Owner: Hermes
- Branch/worktree: `task/NNT-019-container-toolchains`; replaces the original
  NNT-104 branch and PR #1 to align the branch with the corrected task ID.
  NNT-019 was unused in fetched `origin/main`, branches, commits and all PRs.
- Setup exception (retrospective): the user authorized toolchain setup outside
  the normal priority/claim sequence and authorized these review fixes. The task
  record was added with the implementation, not pushed as a pre-implementation
  claim. This note records the exception; it does not rewrite that history.
- Started: 2026-11-05T01:40:42Z
- Updated: 2026-11-05
- Outcome: reusable Rust/Flutter images, disposable checks, isolated PostgreSQL 16,
  persistent per-worktree caches; no host SDKs or production changes.
- Scope: development Compose, Dockerfile, wrapper and setup documentation only.
- Acceptance/evidence: `bash scripts/dev-check.sh build` exited 0;
  `bash scripts/dev-check.sh all` exited 0 twice (cold then warm). Rust 1.99.1:
  fmt, check, clippy `-D warnings`, all 86 tests passed without DB skips.
  Flutter 3.47.9/Dart 3.13.7: release FFI build, analyze and all 6 tests passed.
  PostgreSQL 16.15: healthy/query verified; no published ports, internal network,
  bounded tmpfs/resources, cleanup verified; overlap lock exits 75.
- Review verification: rebuilt both pinned toolchain targets successfully. Full
  `all` passed twice as UID/GID 10001:10001 in an isolated workspace/cache; the
  second run used a fresh HOME. Rust 86/Flutter 6 passed with no database skips;
  all workspace/cache entries remained owned by UID 10001. Flutter HOME settings
  confirmed Linux desktop enabled. Four fast wrapper/Compose tests passed.
  Wiring them into CI was attempted but GitHub rejected the push for missing
  token `workflow` scope; the workflow edit was removed before publication.
- Pinning: Ubuntu and PostgreSQL use inspected immutable image digests; Rust is
  exact 1.99.1; Flutter archive SHA-256 retained. Apt packages/rustup installer
  are not snapshot-pinned; this is not a bit-for-bit reproducible build.
- Issues: native Windows, Android and iOS packaging are outside this Linux setup.
- Handoff: see `docs/CONTAINER-DEVELOPMENT.md` for commands, limitations and job
  prompt recommendation. No production changes or host SDK installs. CI wiring
  remains deferred and is tracked separately as NNT-020.
- Next step: review the PR, confirm CI results and merge only with user approval.

### NNT-100 — Establish repository-based task management

- Priority: P1
- Owner: OpenCode
- Branch/worktree: `main` at `eb6beca`; `AGENTS.md` and `TASKS.md` are uncommitted
- Started: 2026-11-05
- Updated: 2026-11-05
- Outcome: shared rules and authoritative plan for OpenCode, Codex, and Hermes.
- Scope: documentation only; no feature, model, schedule, commit, or push.
- Acceptance: both files exist, consistent, preserve the Windows restart note,
  and contain actionable tasks with stable IDs.
- Depends on: none.
- Verify: manual consistency review of sections, IDs, commands, and paths.
- Handoff: files drafted; no commit per instruction; awaiting review.

### NNT-095 — Updater settings and token diagnostics

- Priority: P1
- Owner: OpenCode
- Branch: `main` at `eb6beca`, tagged `v0.4.1`
- Updated: 2026-11-05
- Outcome: repository/token settings, Test access, clearer 401/404 errors.
- Evidence: commits `1340e18`, `eb6beca`; local Windows build/analyze/tests pass;
  client used the settings UI and exposed the PAT permission error that this task
  now reports clearly.
- Remaining: confirm the `v0.4.1` release assets and PAT-based update (NNT-101,
  NNT-102).
- Next step: after a valid token is configured, run Test access and an update.

## Blocked

### NNT-102 — Validate private-repository PAT flow

- Priority: P0
- Outcome: prove the updater reads a private release and downloads its asset
  using a fine-grained token.
- Scope: token with `Contents: Read`, repository selection, Test access, update
  check, asset download.
- Acceptance: Test access succeeds, update check finds `v0.4.x`, download passes
  SHA-256 and installs.
- Depends on: a valid read-only token.
- Verify: client Update settings, release assets, file hash.
- Blocker: the stored PAT is valid for `ravand1990` but returns 404 for
  `ravand1990/nntdrive`; it lacks repository access.
- Next action: create a fine-grained token with **Contents: Read** for the
  repository (or a classic token with `repo`), then retry Test access.
- Owner: — · Branch: —

### NNT-103 — End-to-end Windows/Linux self-update

- Priority: P0
- Outcome: update an installed older build to the current release without manual
  file copying.
- Scope: install `0.4.0`, configure updates, install `0.4.1`, confirm restart and
  version; Linux equivalent.
- Acceptance: app exits, files are replaced, new version starts, data and sync
  journal remain intact.
- Depends on: NNT-101, NNT-102.
- Verify: process/version check before and after, checksum verification, manual
  UI check.
- Blocker: NNT-102 needs a valid token; NNT-101 must confirm the release first.
- Owner: — · Branch: —

## Done

### NNT-090 — Streaming sync and remote hash cache

- Priority: P2
- Outcome: sync streams files and detects remote file renames.
- Evidence: commit `cbaba7f`; Rust sync/client tests and Dart FFI smoke passed.

### NNT-091 — Selective sync and conflict review

- Priority: P2
- Outcome: per-folder exclusions and a conflict review panel.
- Evidence: commits `dcbe0da`, `a425806`; two-device exclusion test passes.

### NNT-092 — Admin user/provider editing

- Priority: P2
- Outcome: in-place user/provider edits, provider-type dropdown, dashboard
  cleanup.
- Evidence: commit `3f6110f`; backend admin CRUD test passes.

### NNT-093 — Client builds in GitHub releases

- Priority: P2
- Outcome: Windows, Linux, Android assets attached to tagged releases.
- Evidence: commit `b4d2ac9`; `v0.2.1` release assets verified.

### NNT-094 — Windows/Linux auto-updater

- Priority: P2
- Outcome: GitHub release check, checksum verification, staged in-place replace,
  restart.
- Evidence: commit `4183689`; `v0.3.0` release includes `SHA256SUMS.txt`.

## Focused questions

1. When will the repository/releases become public? (NNT-015)
2. What defines a Nightly build: tag pattern, cadence, and retention? (NNT-018)
3. If/when a Windows code-signing certificate becomes available, who owns it and
   what identity should it use? (NNT-006)
4. For anonymous sharing links, what defaults and limits apply (expiry, password
   requirement, download quota)? (NNT-008)
5. On Linux systems without Secret Service, should key storage refuse to start or
   offer an explicit degraded fallback? (NNT-002)
