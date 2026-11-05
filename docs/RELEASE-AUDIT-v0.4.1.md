# v0.4.1 release audit (NNT-101)

Audited 2026-11-05 using authenticated GitHub API reads, downloaded release
assets, Python hashlib SHA-256, and release job logs. No release was modified,
image pulled or deployed, or native platform application launched.

## Verified

- Annotated tag `v0.4.1` resolves to commit
  `eb6beca0883995a7597f5a1c681656b7d2849459`.
- [Release run 41944403569](https://github.com/ravand1990/nntdrive/actions/runs/41944403569)
  completed successfully. Test, image, client analyze, Linux, Android, Windows,
  and GitHub release jobs succeeded.
- CI run `41944400153` and Clients run `41944400113` also report success.
  This is workflow evidence, not local Windows/macOS validation.
- The release image job log confirms successful manifest pushes for `0.4.1`,
  `0.4`, `latest`, and `sha-eb6beca`, all at
  `sha256:803d9eaf45d00b59fc15e84f76bfa3d1d0c82bce60c240169174d6fdd78f404e`.
  Workflow targets `linux/amd64`; registry pull/runtime health was not tested.
- All seven expected release assets exist and were downloaded. Each downloaded
  asset matches its GitHub API SHA-256 digest and declared byte size.
- `SHA256SUMS.txt` contains exactly the three client entries below; all match
  locally computed hashes. Deployment files are not covered by this checksum
  file (consistent with the current workflow), but match API digests.

| Client asset | SHA-256 |
|---|---|
| `nntdrive-android.apk` | `94439e7efe90cddbb00fe61445454bf389d58f15989b6b51b65409631654b0cc` |
| `nntdrive-linux-x64.tar.gz` | `8a51c9f9646e22f7b439141005a4e2e4442e44c667ae70ee996f4facdee57b23` |
| `nntdrive-windows-x64.zip` | `feef6e76dcc28363de4bbd1e699aa70bfa6f0359787676790e12663cc0fbfcd1` |

The other assets are `docker-compose.release.yml`, `env.release.example`,
`README-IMAGES.md`, and `SHA256SUMS.txt`.

## Explained non-blocking failure

Release job `126977392475` (`clients / build-ios`) failed at
`flutter build ios --no-codesign --debug`. Its log reports
`Application not configured for iOS`. The tagged client workflow explicitly
sets `continue-on-error: true`; iOS has no upload step and is not promised in
the release notes. The standalone Clients run has the same failed step.
This is an existing documented platform limitation, not a successful iOS build.

## Acceptance discrepancy: coordinator decision required

NNT-101 literally requires notes containing **Features and Bug fixes**. The
published notes contain **Bug fixes only**, matching the tagged `CHANGELOG.md`
0.4.1 section (two bug-fix bullets). The changelog's stated release policy
allows Features **and/or** Bug fixes, so publishing succeeded legitimately,
but the stricter task acceptance is not met.

Do not invent a feature or rewrite the historical release to make the check
pass. Next action: the coordinator must either accept bug-fix-only categorized
notes for this patch release and explicitly adjust NNT-101 acceptance, or
provide an accurate missing feature and authorize correcting release notes.
Until then NNT-101 remains Blocked, not Review/Done. No second task was started.

## Local verification scope

This is a read-only release audit plus Markdown handoff. `git diff --check`
was run; Rust/Flutter SDK suites were not run because no executable code,
packaging, workflow, or container configuration changed. Downloaded binaries
were hashed, not executed. No self-update, real NNTP, or deployment test occurred.
