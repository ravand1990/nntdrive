# Parser fuzzing groundwork — issue #67

This separate Cargo workspace contains libFuzzer targets for the public yEnc,
NZB and article parsers. It does not change production parsing behavior or the
application dependency lockfile. Synthetic seeds also run in ordinary Rust tests
(`crates/nntp/tests/fuzz_seeds.rs`). The yEnc and article targets additionally
check binary encoding/dot-stuffing round trips; NZB exercises the existing
parser's tolerance, not strict schema validation.

## Current verification boundary

The targets and Docker image are groundwork, **not a completed fuzz campaign**.
The image built locally with Rust `1.102.0-nightly (6905905bb 2026-11-19)` and
cargo-fuzz `0.13.2`. The scheduled worker's approval guard rejected the first
custom Docker execution before it started. No alternate execution path was used.
The fuzz workspace has not been resolved/locked, compiled or executed yet.

Before using this increment, an operator/coordinator must approve a reviewed
isolated runner. It must keep the existing repository check isolation rules:
per-worktree OS-held lock; bounded build and run deadlines; no host credentials,
Docker socket, deployment volumes or provider traffic; networked fetch separate
from offline build/campaign execution; private writable state and read-only source.
Do not install the nightly SDK on the host.

Required runner contract (still to implement and exercise):

- Pin `nightly-2026-11-20`, cargo-fuzz `0.13.2` and libfuzzer-sys `0.4.13`;
  generate and commit the fuzz workspace lockfile after resolution.
- Limit each execution container to 2 CPUs, 6 GiB memory and 256 PIDs. Build
  sequentially with Cargo jobs=2 and an outer 15-minute deadline.
- Run each target sequentially with `-max_len=65536 -rss_limit_mb=2048
  -malloc_limit_mb=1024 -timeout=5 -max_total_time=60 -seed=67`, plus a hard
  outer 90-second deadline and forced cleanup of only that run's container.
- Both raw-input targets and harnesses reject inputs over 65,536 bytes.
- Copy tracked seeds into a private writable corpus. Keep newly generated corpus,
  findings and full logs under mode-0700 ignored per-worktree state; logs and
  artifacts mode 0600. Never automatically upload crash artifacts or raw inputs.
- Record exact source SHA/dirty state, image ID, toolchain versions, limits,
  elapsed time, exit status and libFuzzer coverage/execution counts per target.
  Timeout, OOM, zero execution or missing instrumentation is not success.
- Privately triage any discovered failure before publishing a minimized ordinary
  regression or a security-sensitive finding. A short clean run is not an audit
  or an assurance of parser safety.

Ordinary seed checks use the existing approved wrapper:

```bash
bash scripts/dev-check.sh rust
```

No campaign command is advertised as working until the runner is implemented
and actually exercised. Do not bypass an approval denial through another tool.
