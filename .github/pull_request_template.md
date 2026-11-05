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

Do not use a closing keyword. The issue stays open until acceptance is verified
and the user approves; merge alone does not mark the task Done.

Automatic code PR merge is user-authorized for NNTDrive only under the complete
exact-head required-check, review and acceptance gate in
`docs/GITHUB-TASK-ISSUES.md`. Record the head SHA, expected workflow/job results,
acceptance evidence and any blockers. Unperformed required manual acceptance,
missing/inaccessible evidence, unresolved blocking reviews and required checks
that are not successful block merge. iOS is currently informational only.
No deployment, destructive operations or protection bypass is authorized.
