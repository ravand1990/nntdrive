# GitHub Issues task workflow and migration

Migration date: 2026-11-05. GitHub Issues are the single source of truth for task
requirements, status, priority, dependencies, ownership, and handoff. `TASKS.md`
is now only a pointer.

## Issue workflow

Open tasks:

<https://github.com/ravand1990/nntdrive/issues>

Status labels (exactly one per open issue):

- `status:backlog` — accepted or proposed, not ready
- `status:ready` — defined, unblocked, safe to claim
- `status:in-progress` — claimed and being implemented
- `status:review` — implementation and evidence ready for review
- `status:blocked` — blocked by a dependency or decision

Priority labels (exactly one per issue):

- `priority:P0` — security, data loss, or release blocker
- `priority:P1` — current milestone
- `priority:P2` — planned later

Closed issues represent completed or explicitly cancelled tasks. Leave a closure
comment with the reason and evidence; do not leave a status label on a closed
issue. Use the issue templates for new tasks and bugs.

Issue bodies use this structure:

- Outcome
- Scope / exclusions
- Acceptance criteria
- Dependencies (linked as `NNT-xxx (#issue)`)
- Verification
- Ownership / branch / linked PR
- Handoff / blockers

Manual status transitions are required. There are no GitHub Projects or
automations in this migration; no Project is needed for worker operation.
Comments and labels are coordination, not an atomic lock.

## Ownership and claiming

1. Read the issue body, comments, labels, assignees, linked PRs, dependencies and
   relevant branches/worktrees.
2. Check for a claim comment, `status:in-progress`/`status:review`, an assignee,
   and a branch/PR containing the NNT-ID.
3. Claim by posting a comment with worker, branch, worktree and start time, then
   set exactly one `status:in-progress` label and assign the responsible account.
4. Read the issue back and recheck for competing claims before editing code.
5. Use an isolated branch/worktree, implement one task, and record verification
   on the issue/PR.
6. Set `status:review` when implementation is ready. Do not close until
   acceptance is verified and the user approves.

If claims race or records disagree, stop and ask the coordinator. Never take an
issue already claimed or awaiting review.

## MCP verification

Configured client in this environment: OpenCode, GitHub remote MCP endpoint
`https://api.githubcopilot.com/mcp/`. The exported tools match the official
`github/github-mcp-server` issue tool family.

Verified through MCP on 2026-11-05:

| Capability | Tool | Result |
|---|---|---|
| List issues | `github_list_issues` | 22 open / 9 closed (including test issue) |
| Search issues | `github_search_issues` | Returned issue #24 for `NNT-019` |
| Read issue | `github_issue_read` | Body, labels, assignees, state |
| Read comments | `github_issue_read` (`get_comments`) | 2 comments on test issue |
| Create issue | `github_issue_write` (`create`) | Issue #4 created |
| Update body | `github_issue_write` (`update`) | Body changed and read back |
| Update labels | `github_issue_write` (`labels`) | `status:in-progress`, `priority:P1` applied |
| Assign | `github_issue_write` (`assignees`) | `ravand1990` assigned |
| Comment | `github_add_issue_comment` | Claim and closure comments added |
| Close / reopen | `github_issue_write` (`state`) | Closed, reopened, closed again |

Temporary verification issue #4 was closed as a test and is not a project task.
All 30 migrated task issues were read back through MCP and have the required
sections. The 22 open issues each have exactly one status and one priority
label; the 8 closed task issues each have one priority label and no status label.

Label creation and bulk issue creation used the authenticated GitHub REST API as
a fallback. That is not MCP proof; the MCP write/read operations above are.

Other clients:

- **Codex**: no GitHub MCP server entry found in `C:\Users\ravand\.codex\config.toml`
  during discovery. Unverified.
- **Hermes**: scheduled worker configuration was not accessible from this
  environment. Unverified; see the cutover section.

## Migration mapping

30 `TASKS.md` entries migrated exactly once. Issue numbers and NNT-IDs are
different identifiers.

| NNT-ID | Issue | Status | Title |
|---|---|---|---|
| NNT-020 | [#5](https://github.com/ravand1990/nntdrive/issues/5) | Backlog | Protect container development checks against CI drift |
| NNT-001 | [#6](https://github.com/ravand1990/nntdrive/issues/6) | Backlog | Background sync service |
| NNT-002 | [#7](https://github.com/ravand1990/nntdrive/issues/7) | Backlog | Secure local key storage |
| NNT-003 | [#8](https://github.com/ravand1990/nntdrive/issues/8) | Backlog | AMK epoch rotation on device revocation |
| NNT-004 | [#9](https://github.com/ravand1990/nntdrive/issues/9) | Backlog | Remote folder rename as move |
| NNT-005 | [#10](https://github.com/ravand1990/nntdrive/issues/10) | Backlog | Per-file sync progress and conflict resolution UI |
| NNT-006 | [#11](https://github.com/ravand1990/nntdrive/issues/11) | Backlog | Windows installer and clean-VM test |
| NNT-007 | [#12](https://github.com/ravand1990/nntdrive/issues/12) | Backlog | iOS client |
| NNT-008 | [#13](https://github.com/ravand1990/nntdrive/issues/13) | Backlog | Sharing and public links |
| NNT-009 | [#14](https://github.com/ravand1990/nntdrive/issues/14) | Backlog | Virtual drives and native mobile integrations |
| NNT-010 | [#15](https://github.com/ravand1990/nntdrive/issues/15) | Backlog | Provider/admin operations completion |
| NNT-011 | [#16](https://github.com/ravand1990/nntdrive/issues/16) | Backlog | Security review and hardening |
| NNT-012 | [#17](https://github.com/ravand1990/nntdrive/issues/17) | Backlog | Test gaps |
| NNT-013 | [#18](https://github.com/ravand1990/nntdrive/issues/18) | Backlog | Multi-arch container image |
| NNT-014 | [#19](https://github.com/ravand1990/nntdrive/issues/19) | Backlog | Mobile update distribution (deferred decision) |
| NNT-015 | [#20](https://github.com/ravand1990/nntdrive/issues/20) | Backlog | Repository visibility and PAT retirement |
| NNT-016 | [#21](https://github.com/ravand1990/nntdrive/issues/21) | Backlog | Documentation drift |
| NNT-018 | [#22](https://github.com/ravand1990/nntdrive/issues/22) | Backlog | Update channels (Default / Nightly) |
| NNT-017 | [#23](https://github.com/ravand1990/nntdrive/issues/23) | Ready | Check for updates on every startup |
| NNT-019 | [#24](https://github.com/ravand1990/nntdrive/issues/24) | Done | Containerized local development checks |
| NNT-100 | [#25](https://github.com/ravand1990/nntdrive/issues/25) | Done | Establish repository-based task management |
| NNT-095 | [#26](https://github.com/ravand1990/nntdrive/issues/26) | Review | Updater settings and token diagnostics |
| NNT-102 | [#27](https://github.com/ravand1990/nntdrive/issues/27) | Blocked | Validate private-repository PAT flow |
| NNT-103 | [#28](https://github.com/ravand1990/nntdrive/issues/28) | Blocked | End-to-end Windows/Linux self-update |
| NNT-090 | [#29](https://github.com/ravand1990/nntdrive/issues/29) | Done | Streaming sync and remote hash cache |
| NNT-091 | [#30](https://github.com/ravand1990/nntdrive/issues/30) | Done | Selective sync and conflict review |
| NNT-092 | [#31](https://github.com/ravand1990/nntdrive/issues/31) | Done | Admin user/provider editing |
| NNT-093 | [#32](https://github.com/ravand1990/nntdrive/issues/32) | Done | Client builds in GitHub releases |
| NNT-094 | [#33](https://github.com/ravand1990/nntdrive/issues/33) | Done | Windows/Linux auto-updater |
| NNT-101 | [#34](https://github.com/ravand1990/nntdrive/issues/34) | Done | Verify v0.4.1 release artifacts and notes |

Counts: 30 source entries, 30 issue mappings, 22 open (18 backlog, 1 ready,
1 review, 2 blocked), 8 closed. Temporary MCP issue #4 is excluded.

## Reconciliation and exceptions

- `NNT-019` was still `Review` in `TASKS.md`; PR #2 was merged with green CI and
  the user approved it. It is closed as Done, with `NNT-020` (#5) tracking the
  remaining CI wiring follow-up.
- `NNT-100` was still `Review`; the original `AGENTS.md`/`TASKS.md` work was
  committed in `3e8084e`, and this migration supersedes that tracker. It is
  closed as Done with the superseding reason recorded.
- `NNT-101` was already Done in `TASKS.md` and is closed with the release audit
  evidence.
- `NNT-095` remains open in `status:review`; PAT validation is still blocked by
  `NNT-102` (#27).
- `NNT-102` and `NNT-103` remain open and `status:blocked`.

Links to PR #2 and PR #3 were added to the corresponding issue bodies and the PR
descriptions.

## Hermes cutover

The sole NNTDrive Hermes cron job was accessed on 2026-11-05. Its schedule,
model, provider, reasoning, skills, workdir and Git authentication were
preserved. The job is **paused** until this PR is merged and the cutover is
authorized.

Preserved settings:

- every-two-hour schedule
- `gpt-6.1-sol` via `openai-codex`
- minimal reasoning
- existing skills, workdir, Git author and authentication
- one-task-per-run and no-merge policy

The prompt now reads `AGENTS.md`, `docs/GITHUB-TASK-ISSUES.md`, and GitHub Issues
instead of `TASKS.md`; claims and handoffs go to the issue. It prefers GitHub MCP
issue tools and may use the existing authenticated GitHub API skill if MCP is not
configured for Hermes. It must report which path it used and must not fall back
to `TASKS.md`.

Operator checklist:

1. Keep Hermes paused until this migration PR is merged and the `TASKS.md`
   pointer is live. Do not allow simultaneous selection from both trackers.
2. Merge this migration PR only after user review and CI.
3. Run one Hermes job manually or wait for one scheduled run and verify it
   selects a `status:ready` issue, posts a claim, updates labels, and never
   merges or closes without acceptance.
4. Resume the job only after that verification. Do not change its schedule,
   model, provider, reasoning, skills, workdir, Git author, or no-merge policy.
5. Do not create another tracking service, Project board, or schedule.

## Cutover state and remaining blockers

- Issues are live and verified. The repository still contains the old `TASKS.md`
  until this migration PR (#35) is merged; this is the migration window, not a
  second authoritative tracker. Hermes is paused.
- The migration PR must remain unmerged for user review.
- OpenCode GitHub MCP access is verified. Codex has no GitHub MCP entry and is
  unverified. Hermes has no GitHub MCP server entry; its existing GitHub API skill
  is the fallback, and MCP for Hermes remains unverified.
- No GitHub Project is required, and none is configured. If a Project is added
  later, it must be a view of these issues and must not introduce conflicting
  status fields.
- Labels are not an atomic lock. Multiple agents can share one GitHub account;
  claim comments and rechecks are mandatory.
