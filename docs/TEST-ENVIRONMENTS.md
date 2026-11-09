# Declarative test environments — issue #53 first increment

Run from a trusted checkout; Bash and Python 3 (stdlib only) are required:

```bash
bash scripts/test-env.sh linux-core
# Supply GITHUB_TOKEN through the invoking environment/secret manager, never a CLI argument.
bash scripts/test-env.sh android-emulator --ref task/example --sha FULL_40_CHARACTER_LOWERCASE_SHA
bash scripts/test-env.sh windows-runtime # intentionally fails until provisioning is approved
```

`envs/matrix.yaml` is JSON-compatible YAML parsed by `json`, with schema version
`1` and exactly six named `targets`. Each record has an `executor` (`local`,
`github`, `blocked`) and positive `timeout_seconds`; local records have a
repository-relative argv `command`, hosted records an expected `artifact` and
honest `coverage`, blocked records a human-action `reason`. Shared `toolchains`
records point to authoritative Compose/workflow definitions and declare current
versions (Rust stable remains explicitly rolling on hosted runners).
`hosted_command` declares the manual workflow, inputs and reusable suite; changing
the workflow identity requires a coordinated launcher change. Changes to this
trusted executable configuration require review. The launcher rejects unknown
schema versions/target sets/executors; it is not a general YAML interpreter.

| Target | Execution and limit | What remains unverified |
|---|---|---|
| linux-core | Existing `dev-check.sh all`, 60 minutes | Requires Docker, pinned images and wrapper disk admission; no GUI |
| linux-client | Hosted Clients then release-bundle Xvfb smoke, 90-minute wait | No installed GUI sync/update scenario; hosted execution still needs verification |
| android-build | Hosted Clients, 90-minute wait | APK packaging is not device E2E |
| android-emulator | Hosted Clients including KVM native smoke, 90-minute wait | Smoke tests crypto/private storage, not backend sync |
| windows-build | Hosted Clients, 90-minute wait | Not installer, clean-machine launch, update or restart acceptance |
| windows-runtime | Refused before token lookup/dispatch | Human must choose isolated host, budget, provisioning and trust policy |

Hosted targets currently invoke the **entire unchanged reusable Clients suite**;
the selected target determines expected artifact/coverage, not job filtering.
This deliberately keeps analysis and every native check blocking and reuses the
APK's actual native library for Android runtime. It is more expensive than a
future target-specific workflow. Existing nine CI/Clients acceptance checks
are unchanged; the manual workflow neither replaces them nor publishes anything.
No self-hosted workflow is created, and arbitrary PR code must never gain a
privileged runner or production credentials. A future Windows runtime environment
needs explicit approval and ephemeral isolation, not a generic `self-hosted` label.

## Identity, credentials and failure contract

- Workflow `test-environments.yml` is manual-only, with read-only Contents
  permission, no inherited secrets, release/deploy steps or publication. GitHub
  requires the dispatch workflow to exist on the default branch before use.
- The caller supplies explicit branch/tag `--ref` and full `--sha`. Raw commit
  SHAs (including abbreviated SHA-like refs) are rejected as `--ref`; dispatch
  requires a branch or tag, not merely a resolvable commit. The API resolves the ref
  before dispatch and again before accepting success. A moving ref fails closed.
  The workflow's identity job also checks the actual `github.sha` before Clients.
- A fresh random UUID hex correlation is included in inputs and exact run title.
  Discovery requires that title, head SHA and `workflow_dispatch` event; unrelated
  concurrent runs cannot satisfy it. Duplicate matches and rerun attempts fail.
- Only `GITHUB_TOKEN` from runtime is accepted. Use a narrowly scoped token with
  Actions write (dispatch), Actions read and Contents read on the chosen repo.
  No credential file paths, token CLI options, API host overrides, response-body
  logging or redirect following. Do not invoke untrusted checkout code with a
  write token. The local toolchain child has `GITHUB_TOKEN` removed.
- `--timeout SECONDS` can only shorten the declared budget. Requests are capped
  at 30 seconds and remaining deadline; polling sleeps at most five seconds,
  pagination at most 100 pages. A POSIX signal timer enforces the outer hosted
  wall-clock deadline even during blocking transport/body reads; hosts without
  `setitimer` fail before dispatch. Deadlines are checked after responses and
  before success too. HTTP/rate-limit/transport/malformed responses,
  unsuccessful/skipped/cancelled runs and missing/expired/duplicate artifacts
  return nonzero. No retries silently mask errors. Local termination signals the
  process group with up to 15 seconds of cleanup grace; inspect Compose cleanup
  after forced termination.
- The exact run URL is printed when discovered. A successful run must have the
  expected nonempty nonexpired artifact, whose exact UI URL is printed. No
  downloads or production provider access are performed. On timeout the remote
  workflow is **not cancelled**: use its printed URL or correlation title to
  inspect/cancel it explicitly. Do not mistake a deadline for remote cleanup.
- Run-level success alone is insufficient. The launcher fully paginates attempt
  1 jobs and requires exactly one completed successful `identity`, `analyze`,
  `build-linux`, `build-android`, `build-windows`, `android-native-smoke` and
  `windows-app-smoke`.
  Reusable job names may be bare or prefixed `clients / `; duplicates across
  either spelling fail. A build-only APK never substitutes for Android smoke.
  `linux-client` additionally requires successful `linux-runtime` and exactly
  one nonempty, nonexpired `nntdrive-linux-runtime-evidence` artifact.

## Linux release-bundle runtime gate

For `linux-client`, the manual workflow waits for the entire reusable Clients
suite, downloads that run's `nntdrive-linux-x64` artifact with the repository's
pinned download action, and launches the actual packaged executable/native library.
A fresh Xvfb display runs in a network namespace with no network interfaces
connected to deployment services. The child environment is allowlisted; HOME and
all XDG directories are fresh, checkout credentials are not persisted, and no
credential files or host homes are mounted. Runtime packages are installed only
on the disposable hosted runner, not on development hosts.

`scripts/smoke-linux-client.py` requires a live executable process and a visible
X11 window belonging to that exact PID continuously for at least three seconds.
An early exit, missing native library, absent window, capture failure or timeout
fails the job and therefore the `linux-client` run. Other existing workflow choices
retain the full Clients suite without requiring this Linux-only job.

The always-run evidence upload contains client/runner/Xvfb logs, screenshot,
source SHA and a JSON report with archive SHA-256, PID/window title and pass/fail.
Screenshot capture is best effort on failure (an unavailable X server cannot
produce one). The reported version comes explicitly from the same checkout's
`clients/flutter/pubspec.yaml`, not an invented application `--version` switch.
The GUI window title is recorded, but GUI version remains **not observed**;
a screenshot can be inspected manually if the application exposes it. This is a
cold unauthenticated launch, not backend sync, update, login or persistence E2E.

## Local contract verification and remaining acceptance

```bash
python3 scripts/test-test-env.py
python3 scripts/test-smoke-linux-client.py
bash -n scripts/test-env.sh
```

Subprocess tests mock the stdlib HTTP transport inside a child process (no live
GitHub writes). They exercise correlation amid unrelated runs, exact artifact
URLs, wrong heads/titles, duplicate matches, failed runs, reruns, missing/expired
artifacts, invalid inputs, absent tokens, API failures, local delegation and the
Windows provisioning refusal, paginated/missing/skipped/cancelled/duplicate jobs,
Linux runtime evidence, raw-SHA refs and late final responses beyond the budget.
Linux helper subprocess contracts use a fake bundle
and mocked X11 tools to verify process/window gating, environment filtering,
cleanup, safe extraction and failure reporting; they are not GUI evidence.
Existing CI wrapper-contracts runs both suites.

The local `linux-core` target passed the isolated Rust/PostgreSQL and Flutter
suites in the existing task checkout. Hosted dispatch and live Linux bundle smoke
remain **unverified on the hosted runner** until this manual workflow is registered
and explicitly dispatched after integration. Android uses the existing native
crypto/private-storage emulator smoke, not release-APK launch/backend-sync E2E.
Windows runtime provisioning and clean-machine installed/update acceptance remain
deferred; the existing hosted process/window smoke does not establish them.
These gaps are follow-up work, not evidence supplied by mocked API responses.
