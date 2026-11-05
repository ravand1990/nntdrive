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
| Todo | Not implementing; may be Backlog or Ready for scheduling |
| In Progress | Claimed implementation |
| Ready For Review | Implementation/evidence handed off; not accepted |
| Blocked | Explicit dependency, decision or environment blocker |
| Done | Accepted and completed; retain closed completed tasks on the board |

No new column or automation was added. Cancelled and verification/test issues
must not be represented as completed work. Test issue #4 is excluded.

## Scheduling readiness is not phase

Every task body contains a `Scheduling readiness` heading followed by exactly
`Ready` or `Backlog` (Markdown `##` for migrated bodies, `###` from GitHub issue
forms; both are valid). This is queue authorization, not a second progress tracker.
Both old Backlog and Ready map to Todo, but only Todo **and** readiness Ready
can be considered for new selection. Missing/ambiguous membership, Status or
readiness is not permission to work. Never promote Backlog automatically.
Ready still requires satisfied dependencies and unambiguous lack of ownership.
Review/Blocked/In Progress retain Ready authorization without becoming eligible;
closed tasks remain ineligible regardless of readiness.

At cutover, old Ready and already active/review/blocked tasks retained Ready;
old Backlog retained Backlog. Historical closed tasks received conservative
Backlog, because completion is not authorization for a new run.
New tasks default to Todo plus Backlog, with one priority label. After creating
an issue, add it to this Project, explicitly set Todo and verify membership,
Status and readiness; issue forms alone do not enroll it or set Project fields.
Only the coordinator/user may explicitly authorize readiness Ready.
Use `priority:P0` security/data loss/release blockers, `priority:P1` current milestone,
`priority:P2` later work. Preserve other non-status labels.

Task bodies retain Outcome, Scope / exclusions, Acceptance criteria,
Dependencies, Verification, Ownership / branch / linked PR, Handoff / blockers,
and Scheduling readiness. Link dependency issues, not a duplicate task list.

## Discovery, claims and handoff

1. Read issue body/comments, assignees, priority, dependencies and linked/open
   PRs; inspect local/remote branches, commits and worktrees. Read the Project
   membership and Status with full pagination, not issue label search.
2. Select the highest-priority unowned open Todo + Ready task with satisfied
   dependencies. Skip owned/claimed/PR-linked/Review/Blocked candidates and
   continue through independent eligible tasks. One task per run does not limit
   the repository to one open PR. Do not infer acceptance from merge alone.
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
3. Publish an agent-identifying claim comment with branch/worktree/start time;
   set Project Status In Progress, assign the responsible account where
   appropriate, read back the exact item and issue, and recheck competing claims.
   Comments, assignments and Project transitions are coordination, not locks.
4. Use an isolated task branch/worktree; resume only your own unfinished work
   with clear coordinator authorization. Name migrated-task branches
   `task/<NNT-ID>-<slug>` and new-task branches `task/issue-<number>-<slug>`;
   include the same identifier in commits and PR titles. Review handoffs are not unfinished
   implementation. Preserve other agents' work and existing branches.
5. Put actual checks/results, owner, branch/commit, remaining work, blockers,
   PR link and exact next action on the issue. Set Ready For Review after
   implementation; Blocked for a genuine blocker. Read back every write.
   On later runs, objectively revalidate blocked issues not currently In
   Progress before new task selection; time passing alone does not clear a
   blocker.
6. Automatically merge code PRs only under the user-authorized merge gate below.
   Mandatory post-merge reconciliation follows the completion transaction below.
   The user grants standing approval to close verified completed tasks and set
   Done once ALL acceptance criteria and applicable checks are satisfied. This
   is not permission to waive manual acceptance, deploy, or close incidental refs.
   Avoid relying on automatic-closing keywords; they do not reconcile the board.

## User-authorized automatic merge gate (NNTDrive only)

Effective 2026-11-05, the user explicitly authorizes future code PR merges only
in `ravand1990/nntdrive` after every applicable required test/check passes for
the exact current head SHA. This supersedes prior NEVER MERGE instructions in
worker prompts and PR handoffs, not security, scope, ownership or acceptance.
The root tracker/merge policy is aligned at `cc5a753`; only the remaining
separate-approval completion clause is superseded by the standing authorization
below, with the denied normal alignment attempt retained as an operator follow-up.

Before each merge:

- Review the complete diff, issue acceptance criteria and actual evidence;
  unrelated or unsafe changes do not become acceptable merely because CI passes.
- Require a non-draft, conflict-free PR with no rejected review or unresolved
  blocking review thread; satisfy current protection, required reviews, update
  and merge-queue rules. Never use admin/force merges or bypass protection.
- Enumerate all applicable expected workflows/jobs at the current head. Require
  successful completed results, not failed, cancelled, pending or skipped
  required checks. Missing workflows and inaccessible evidence are blockers.
  When Checks/status APIs return 403, exact-head Actions run/job results may
  establish those workflow results only; a 403 is not green or proof that no
  additional protected gate exists. Refresh/rerun checks when required by base
  update rules; never force-rebase another agent's branch.
- Current PR workflows are CI (`rust`, `wrapper-contracts`, `docker`) and Clients
  (`analyze`, `build-linux`, `build-windows`, `build-android`,
  `android-native-smoke`). Inspect the live workflow definitions each time;
  this list is not permission to omit newly applicable gates. iOS is not
  currently built in CI and remains unimplemented. Release/tag-only publishing
  is not an invented PR requirement.
- Tests do not replace required manual acceptance. Merge only when PR acceptance
  is satisfied, or the user explicitly approves a documented follow-up; never
  invent approval. A draft is not automatically ready. Issue closure/Done follows
  the mandatory completion transaction and standing authorization below.
- Use an allowed merge method and expected head SHA; verify merged state, merge
  commit and main remotely. Merge sequentially and fast-forward only a clean
  local main. Enable GitHub auto-merge only if its enforced gates cover every
  applicable required gate and acceptance is already satisfied; otherwise leave
  pending PRs open with exact blockers. Never weaken checks to enable merging.
- Record exact head, commands/results, Actions links, merge commit or blockers
  on the PR/issue. Preserve Project phase authority and priority labels.

This permission does not authorize deployment, destructive operations, branch
or tag deletion, force pushes, or direct-main code changes. The present scoped
policy/documentation update on main is separately user-authorized. A merged PR
is not issue acceptance and does not automatically satisfy dependency acceptance.

## Mandatory post-merge completion transaction

The user's standing authorization covers closing completed issues and setting
Project Done after every acceptance criterion and applicable check is verified;
no separate user approval is required for such tasks. This supersedes the old
separate-approval clause in AGENTS.md only. Its alignment was attempted normally
under renewed explicit consent, but the protected-instruction guard denied it;
no alternate write or bypass was attempted. That file remains an operator fix.

1. Verify actual merged state, expected PR head and merge SHA, and the merge
   commit's inclusion on remote main. For authorized direct-main work, verify
   the integrated commits and their applicable exact-head evidence instead.
2. Identify genuinely linked task issues using PR metadata, task scope and issue
   history; a `Refs` mention alone is not permission to close unrelated work.
   Read full bodies and paginated latest comments. Map ALL acceptance criteria
   to actual check/runtime/manual evidence. Missing evidence fails closed.
3. Post a durable completion handoff on each linked issue with: worker/owner,
   outcome and changes, branch and integrated commit/PR links, exact commands
   and check URLs/results, acceptance evidence, remaining limitations or
   follow-up issue links, and the exact next action (or explicitly none).
   Keep repository-relative references; never publish credentials or private
   infrastructure paths. For blocked/interrupted work, record saved/uncommitted
   state, blocker and resumption instructions before stopping. Preserve prior history,
   priorities, readiness and assignees. Close with reason `completed` and set the
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

All 30 real task issues (#5–#34), 19 open and 11 closed completed, are members
exactly once. Cutover phases: Todo 12 (3 Ready, 9 Backlog), In Progress 0,
Ready For Review 2, Blocked 5, Done 11. Readiness: Ready 10, Backlog 20 (including
11 closed tasks). No issues were closed/reopened or PRs merged by this cutover.
All five obsolete status label definitions were deleted only after membership
and phase readback per issue and zero status-label usage across issues **and
PRs**. Thirteen non-status definitions, issue non-status labels, assignees and
original body text were preserved. Existing mapping NNT-ID → issue number is
unchanged; use the live board, not a dated duplicate phase table.

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
