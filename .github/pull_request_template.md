## Task

Task issue: #

## Summary

<!-- What changed and why? -->

## Verification

<!-- Commands run and actual results. Do not claim unrun checks. -->

- [ ] `cargo fmt`, clippy, and affected tests
- [ ] `flutter analyze` / tests when clients changed
- [ ] Build when packaging or native code changed
- [ ] Docs/CHANGELOG updated when user-visible

## Scope / risk

<!-- What is intentionally out of scope? What remains unverified? -->

## Acceptance

Do not rely on a closing keyword. After merging, the worker MUST verify all
issue acceptance criteria and applicable checks, post merged-commit/check and
acceptance evidence, close the genuinely linked completed issue with reason
completed, set Project Status Done, and read back both. The user's standing
authorization covers verified completed tasks; separate approval is not needed.
Merge alone is not acceptance. Missing runtime/manual evidence leaves the issue
open in Review/Blocked; report the exact next action, never silently waive it.
Even automatically closed issues require board reconciliation; a failed closure
or board write is an incomplete handoff until readbacks succeed.

Automatic code PR merge is user-authorized for NNTDrive only under the complete
exact-head required-check, review and acceptance gate in
`docs/GITHUB-TASK-ISSUES.md`. Record the head SHA, expected workflow/job results,
acceptance evidence and any blockers. Unperformed required manual acceptance,
missing/inaccessible evidence, unresolved blocking reviews and required checks
that are not successful block merge. iOS builds are not currently run in CI.
No deployment, destructive operations or protection bypass is authorized.
