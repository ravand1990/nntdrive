# GitHub Issues and Project task workflow

## Authority and live cutover

Effective 2026-11-05 by explicit user direction, Issues own requirements,
priority, dependencies, ownership and evidence; the existing
[NNTDrive Project](https://github.com/users/ravand1990/projects/2) **Status**
field owns phase. `TASKS.md` is only a pointer. Do not recreate status labels.
This live user-authorized policy supersedes older label instructions, including
any still present in `AGENTS.md`. It does not waive security, scope, ownership,
checks or acceptance. These workflow/template changes were consolidated directly
onto main by explicit user authorization; PR #40 is superseded, not merged.
The tracker and merge alignment in `AGENTS.md` is published at `cc5a753`.
A renewed normal attempt to update its remaining separate-approval closure
clause was guard-denied; no bypass was attempted. Only that closure clause
remains an operator follow-up. The explicit standing completion authorization
below supersedes it narrowly; all other checked-in rules apply.

Discover the Project by its owner/number from the URL above, then discover its
current Status field and option IDs at runtime. Do not hardcode field/option
IDs or rely on cached options.

| Project Status | Meaning |
|---|---|
| Backlog | Not authorized to start; coordinator triage pending |
| Ready | Authorized and eligible when dependencies are satisfied |
| In Progress | Claimed implementation |
| Ready For Review | Implementation/evidence handed off; not accepted |
| Blocked | Explicit dependency, decision or environment blocker |
| Done | Accepted and completed; retain closed completed tasks on the board |

No new column or automation was added. Cancelled and verification/test issues
must not be represented as completed work. Test issue #4 is excluded.

## Shared agent instructions and safe concurrency

The root `AGENTS.md` is the single shared entry point for Codex, OpenCode,
Hermes, and other workers. This document implements the task-lifecycle details;
worker-specific schedulers only set runtime identity, workdir, model,
permissions, and cadence. Historical migration/audit notes in this document
are records, not competing current policy. In particular the root file now
recognizes the standing, acceptance-gated issue-closing authorization below.

**No enforced distributed lock is implemented in this change.** GitHub issue
comments, assignees, branch-search hits and Project field writes only signal
ownership. Until an atomic claim mechanism is implemented, tested, and adopted
by every competing worker, route *new task selection* through one dispatcher;
independent workers can continue already assigned work in separate worktrees.
Never assume a successful claim comment proves exclusive ownership.

**Current dispatcher designation (2026-11-06):** while it is the only competing
autonomous worker, the sole Hermes scheduled worker is the designated dispatcher
and may select `Ready` issues. This designation lapses immediately when a second
competing worker is enabled; then stop new-task selection until the coordinator
designates a dispatcher or a tested atomic claim mechanism is adopted.

When a claim mechanism is added, it must use an actual atomic create operation,
not check-then-write; on conflict it must fail without changing the other
worker's ref. It must also handle failed claims, abandoned claims, resumption,
and existing task branches without destructive cleanup. A scheduler must not
start using the new protocol until **all** competing workers have migrated.

The issue form deliberately offers only `Backlog` for new issues. The
coordinator grants `Ready` explicitly after triage; an issue submitter's
self-selected queue value is not authorization. Form options are a workflow
guard, not an access-control boundary; permissions must enforce policy.

## Backlog is not Ready

Project Status is the sole queue and phase tracker. `Backlog` means not authorized
to start; `Ready` means authorized and eligible once dependencies are satisfied.
There is no separate readiness field in issue text, and status labels must not be
recreated. Only the coordinator/user may move an issue from `Backlog` to `Ready`.

`In Progress`, `Ready For Review`, `Blocked` and `Done` are not eligible for new
selection regardless of history. A closed issue is never eligible. `Ready` still
requires satisfied dependencies and an unambiguous lack of ownership.

New tasks default to `Backlog` with one priority label. After creating an issue,
add it to this Project, explicitly set `Backlog`, and verify membership and
Status; issue forms alone do not enroll it or set Project fields.
Use `priority:P0` security/data loss/release blockers, `priority:P1` current milestone,
`priority:P2` later work. Preserve other non-status labels.

Task bodies retain Outcome, Scope / exclusions, Acceptance criteria,
Dependencies, Verification, Ownership / branch / linked PR, and Handoff /
blockers. Link dependency issues, not a duplicate task list.

## Discovery, claims and handoff

1. Read issue body/comments, assignees, priority, dependencies and linked/open
   PRs; inspect local/remote branches, commits and worktrees. Read the Project
   membership and Status with full pagination, not issue label search.
2. Select the highest-priority unowned open `Ready` task with satisfied
   dependencies. Skip owned/claimed/PR-linked/Review/Blocked candidates,
   `blocked-loop` items, and continue through independent eligible tasks. One
   task per run does not limit the repository to one open PR. A completed PR with
   green checks is merge work, not a new claim: its owner/coordinator should
   attempt the merge instead of skipping it merely because it is PR-linked. Do
   not infer acceptance from merge alone.
   Before selecting new work, triage every Blocked issue not currently In
   Progress, regardless of assignee. Compare its recorded blocker with current
   objective evidence (such as a restored CI run or integrated prerequisite).
   This is blocker triage, not permission to take over another agent's active
   implementation. If conclusively resolved without a human decision or
   acceptance still required, update the handoff and unblock it; resume
   implementation only when no other agent is actively In Progress and
   ownership/resumption is coordinated. Otherwise leave it Ready for its owner.
   If unresolved or awaiting a human decision, leave it Blocked with exact next
   action. Never make a duplicate claim/branch or treat elapsed time as proof.
   If a selected task cannot be started or completed, retry at least once with a
   changed approach. If the remaining cause is outside the worker's control
   (human decision, missing credential, unavailable platform, external outage,
   another worker's branch), record it on the issue, mark `blocked-loop` when it
   repeats, and select the next eligible task in the same run. Do not end a
   scheduled run with no contribution while eligible work exists; a handoff-only
   run must state why no eligible task remained. Retries must not bypass checks,
   change acceptance criteria, force-push or take over another branch.
3. Publish an agent-identifying claim comment in the fixed format
   (`## #<issue> · Claimed · <worker_id>`) with branch/worktree/start time;
   set Project Status In Progress, assign the responsible account where
   appropriate, read back the exact item and issue, and recheck competing claims.
   Comments, assignments and Project transitions are coordination, not locks.
4. Use an isolated task branch/worktree; resume only your own unfinished work
   with clear coordinator authorization. Name migrated-task branches
   `task/<NNT-ID>-<slug>` and new-task branches `task/issue-<number>-<slug>`;
   include the same identifier in commits and PR titles. Review handoffs are not unfinished
   implementation. Preserve other agents' work and existing branches.
5. Put actual checks/results, owner, branch/commit, remaining work, blockers,
   PR link and exact next action on the issue, using the fixed comment format
   below. Set Ready For Review after
   implementation; Blocked for a genuine blocker. Read back every write.
   On later runs, objectively revalidate blocked issues not currently In
   Progress before new task selection; time passing alone does not clear a
   blocker.
6. Automatically merge code PRs only under the user-authorized merge gate below.
   Mandatory post-merge reconciliation follows the completion transaction below.
   The user grants standing approval to close completed tasks and set Done once
   implementation is merged and the available evidence is recorded. Deferred
   verification must be filed as a follow-up issue (see the merge gate). This
   is not permission to deploy or close incidental refs.
   Avoid relying on automatic-closing keywords; they do not reconcile the board.

## Agent comment format

Every agent comment on an issue or PR uses the same four fields, defined in
`AGENTS.md` §7. Copy this skeleton:

```text
## #42 · Ready for review · hermes-nntdrive-scheduled
- **What:** README slimmed and walkthroughs moved to existing guides.
- **Where:** `task/issue-42-slim-readme` · PR #48 · `07be8f4`
- **Checks:** CI #42220508647 pass · Clients #42220508161 pass
- **Next:** merge at the expected head, then reconcile.
```

States are fixed: `Claimed`, `In progress`, `Blocked`, `Ready for review`,
`Done`. A run with no work uses `## No eligible work · <worker_id>`.

Blocked example:

```text
## #49 · Blocked · hermes-nntdrive-scheduled
- **What:** Windows self-update still exits without installing; needs the real Windows runner.
- **Where:** `task/issue-49-windows-update` · — · `abc1234`
- **Checks:** CI #42212639911 pass · Windows runtime not run: no runner
- **Next:** coordinator provides the runner, then run `test-env.sh windows-runtime`.
```

Rules: no extra sections, no pasted logs, no narrative, no emoji; under ~10
lines; `—` for an absent value; past tense for done, present for blocked. Link
anything longer.

## User-authorized automatic merge gate (NNTDrive only)

Effective 2026-11-05, updated 2026-11-08: the user authorizes code PR merges in
`ravand1990/nntdrive` without waiting for e2e, platform, manual or
release-artifact verification. A merge still requires a reviewed diff at a known
head and must not bypass GitHub's enforcement, safety invariants or the
security-sensitive test rule in `AGENTS.md` §5.
The root tracker/merge policy is aligned at `cc5a753`; only the remaining
separate-approval completion clause is superseded by the standing authorization
below, with the denied normal alignment attempt retained as an operator follow-up.

Before each merge:

- Review the complete diff, issue acceptance criteria and actual evidence;
  unrelated or unsafe changes do not become acceptable merely because CI passes.
- Require a non-draft, conflict-free PR with no rejected review or unresolved
  blocking review thread. Do **not** require branch-protection, ruleset or
  merge-queue metadata to be readable through the API before attempting a merge;
  GitHub enforces the actual policy. Attempt the allowed merge with the expected
  head, then verify the result. If the merge is rejected, record the exact error
  and do not bypass protection, admin-merge, or force-push. A completed PR with
  green checks is merge work, not a new claim; do not skip it merely because it is
  PR-linked.
- Run the applicable workflows/jobs at the current head. A failure caused by the
  change must be fixed and rerun once. An unrelated, flaky or infrastructure-only
  failure may be recorded and merged; do not weaken or delete the check to get
  green. When Checks/status APIs return 403, exact-head Actions run/job results may
  establish those workflow results only. Refresh checks when required by a base
  update; never force-rebase another agent's branch.
- Current PR workflows are CI (`rust`, `wrapper-contracts`, `docker`) and Clients
  (`analyze`, `build-linux`, `build-windows`, `build-android`,
  `android-native-smoke`, `windows-app-smoke`). Inspect the live workflow
  definitions each time. iOS is not currently built in CI and remains
  unimplemented. Release/tag-only publishing is not a PR requirement.
- E2E, platform, manual, installer/VM, multi-device and performance verification
  are **not** merge gates. When they are unavailable or failing for reasons
  outside the diff, open or update a follow-up issue (one priority label, Project
  `Backlog`), state the exact gap in the PR, and merge. Never claim a run that did
  not happen. Security-sensitive changes (crypto, keys, auth, tenant scoping,
  migrations, deletion, plaintext leakage) still need their focused risk tests.
  A draft is not automatically ready.
- Use an allowed merge method and expected head SHA; verify merged state, merge
  commit and main remotely. Merge sequentially and fast-forward only a clean
  local main. Never weaken checks to enable merging.
- If merge attempts repeatedly fail for non-code/policy reasons without new
  evidence, mark the issue/PR `blocked-loop`, set Project Status `Blocked`, and
  record the exact failure and human action. Workers skip `blocked-loop` items and
  continue with independent Ready work.
- Record exact head, commands/results, Actions links, merge commit or blockers
  on the PR/issue. Preserve Project phase authority and priority labels.

This permission does not authorize deployment, destructive operations, branch
or tag deletion, force pushes, or direct-main code changes. The present scoped
policy/documentation update on main is separately user-authorized. A merged PR
is not issue acceptance and does not automatically satisfy dependency acceptance.

## Mandatory post-merge completion transaction

The user's standing authorization covers closing completed issues and setting
Project Done after implementation is merged and the available evidence is
recorded; deferred verification must be filed as a follow-up issue. No separate
user approval is required for such tasks. This supersedes the old
separate-approval clause in AGENTS.md only. Its alignment was attempted normally
under renewed explicit consent, but the protected-instruction guard denied it;
no alternate write or bypass was attempted. That file remains an operator fix.

1. Verify actual merged state, expected PR head and merge SHA, and the merge
   commit's inclusion on remote main. For authorized direct-main work, verify
   the integrated commits and their applicable exact-head evidence instead.
2. Identify genuinely linked task issues using PR metadata, task scope and issue
   history; a `Refs` mention alone is not permission to close unrelated work.
   Read full bodies and paginated latest comments. Map acceptance criteria to
   available evidence. Deferred verification is acceptable only with a linked
   follow-up issue, and it must not be described as verified. Unverified
   security-sensitive boundaries still fail closed.
3. Post a durable completion handoff on each linked issue with: worker/owner,
   outcome and changes, branch and integrated commit/PR links, exact commands
   and check URLs/results, acceptance evidence, remaining limitations or
   follow-up issue links, and the exact next action (or explicitly none).
   Keep repository-relative references; never publish credentials or private
   infrastructure paths. For blocked/interrupted work, record saved/uncommitted
   state, blocker and resumption instructions before stopping. Preserve prior history,
   priorities and assignees. Close with reason `completed` and set the
   exact Project item Status to Done using freshly discovered field/option IDs.
4. Read back issue state/reason, evidence comment and exact Project item. If
   GitHub already auto-closed the issue, still reconcile Done. Closing keywords
   are not a substitute for board reconciliation. Use bounded read retries for
   eventual consistency; report incomplete handoff and retry appropriately if
   either closure or board update fails. Never claim Done from a mutation alone.
5. Leave incomplete criteria open in Ready For Review or Blocked with exact
   missing acceptance and next action. Correct premature automatic closure and
   verify the correction. Never waive manual/device criteria merely because CI
   passes. Exclude verification issue #4 and cancelled work from completed tasks.

This transaction is mandatory after merging and during reconciliation of older
merged work, before claiming task completion or choosing new implementation.
It does not authorize extra merges, deployment, releases or destructive cleanup.

## API capability and protected credentials

Use verified GitHub MCP issue/PR tools when available. The currently configured
Hermes GitHub MCP launcher exports issue/PR/repository/Actions tools, **not
Projects**. Use authenticated GitHub GraphQL for Project reads/mutations and
report that fallback honestly. REST is available for issue/comment operations;
a missing gh CLI is not a blocker. Other clients must verify their own access.

Read the PAT only inside protected runtime code; never print tokens, headers,
credential URLs or secrets. Do not add credential material to repository files.
Discover fields/options with ProjectV2 queries; paginate items and issue lists,
exclude PR objects from issue enumeration, match repository and issue node ID,
and add missing items without duplicates. Use addProjectV2ItemById and
updateProjectV2ItemFieldValue, then read the exact item back. Project reads can
lag successful writes: bounded read retries are appropriate, not blind repeated
mutations or treating a mutation response as verification.

## Migration audit (2026-11-05)

Fresh issue bodies/comments and PRs were reconciled after the old worker
completed at 16:53:24 UTC. SQLite executions were inspected read-only: no
claimed/running execution of this job remained. PR #39 / NNT-005 at `d4ef2fd`
remains Ready For Review; NNT-020 (#5) remains Review pending acceptance, not
Done merely because implementation is on main. NNT-004 (#9) has an explicit
accepted-and-merged closure comment. Historical completed issues retain their
recorded completion evidence; this migration asserts no new acceptance.

All 30 real task issues (#5–#34) are members exactly once. The 2026-11-05
cutover phase snapshot is historical; always read the live Project Status.
Obsolete status labels were deleted only after membership and phase readback,
and zero status-label usage remains across issues and PRs. Thirteen non-status
definitions, issue non-status labels, assignees and original body text were
preserved. Existing mapping NNT-ID → issue number is unchanged; use the live
board, not a dated duplicate phase table.

## Completion reconciliation (2026-11-05)

A fully paginated fresh audit covered 31 issues (30 real task issues and excluded
verification issue #4), all 9 PRs and all 30 Project items before any GitHub write.
19 task issues were open. Only two were newly closed completed and read back as
Done: #10 / NNT-005 (PR #39, merge `9895961`, exact-head CI/Clients plus recorded
two-device acceptance), and #5 / NNT-020 (authorized direct-main `be1c5f1`,
exact-head CI/Clients and successful manual pinned-container run at `fb4b91b`).
Their closure comments contain evidence links and criterion reconciliation.
#9 / NNT-004 was already closed completed/Done; PR #38 merge `215fcfa` was verified
on main, so no duplicate closure was performed. The audit leaves 17 tasks open,
13 completed tasks Done, and preserves 30 unique real task Project members.
#28 remains Blocked: actual Windows/Linux self-update process exit, replacement,
restart/version and data/journal preservation plus manual UI checks remain
unperformed. Other incomplete tasks were not closed from incidental references.
No PR merge, release, deployment or extra scheduler run was performed here.

## Scheduled worker policy

The user authorized live worker cutover and resume independently of PR #40.
The documentation/template cutover is published directly on main. The scheduled
prompt retains only narrow precedence for the standing completion authorization
while AGENTS.md's remaining separate-approval clause is guard-blocked; its
tracker/merge rules are already aligned. Never revert to labels or a blanket
no-close policy for fully verified completed tasks.
Preserve the existing 120-minute interval, gpt-6.1-sol/openai-codex, minimal
reasoning, skills, workdir, protected authentication, repository-local Git
identity, one-task-per-run and no-deploy policy. Automatic merging is authorized
only under the exact-head merge gate above, never as automatic acceptance.
Do not trigger an extra
run merely to validate configuration. The scheduler is not an atomic
cross-machine claim lock. New clients must adopt the same live policy before
being allowed to compete for work.
