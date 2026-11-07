# Background sync feasibility and security boundary (NNT-001 / #6)

## Delivery status

This is a **partial background-service delivery**. Windows/Linux now have a
same-process close-to-tray lifecycle: hiding retains the unlocked session and its
single sync controller/timer. Tray actions provide Open, generic sync state,
Pause/Resume and Quit. Closing only hides when a restore path is available;
otherwise it drains and quits. This does **not** implement autostart, automatic
unlock, an independent service, or mobile scheduling.

The unlock screen explains that sync is paused while the vault is locked.
Native regressions reject missing/revoked process-local handles before journal
creation/backend contact. Whole sync rounds and conflict resolution retain the
existing exclusive per-journal operation lease; tray actions never allocate a
second journal namespace or scheduler.

## What prevents unattended cold-start sync today

- `clients/flutter/lib/main.dart` restores the token and **password-wrapped**
  keyfile, then shows `UnlockPage`. `_completeAuth` requires the password and
  calls `NativeBridge.unlockAsync`. Persisting a token is not a decryption grant.
- `crates/ffi/src/lib.rs` stores master keys only in the process-local `HANDLES`
  table. `key(handle)` rejects missing/revoked handles. Each sync entry point
  checks this before opening its journal or making remote requests. An integer
  saved by Dart cannot restore the key after process death or in another process.
- The unlocked application session owns `SyncController` and its five-minute
  Dart timer independently of route/window visibility. There is still no durable
  worker or interprocess unlocked-session transport. Hiding retains an unlocked
  process; restarting it cannot.
- Moving the password-wrapped keyfile into an OS key store (#7) alone does **not**
  unlock it. Automatic unlock would require a separately approved device-key /
  OS-unlock policy. Password remembering (#50) is outside #6 and this change.

Never persist a plaintext password, AMK, or a serialized unlocked handle, pass a
key on a command line, or send it to the backend to satisfy login resumption.
Autostart can safely launch **locked**, visibly requiring user unlock. It cannot
honestly promise automatic encrypted sync after login with today's key policy.
This is a security constraint on cold starts, not a claim that close-to-tray is
impossible while the unlocked process remains alive.

## Same-process desktop behavior

- Closing hides; **Open NNTDrive** restores the same widget tree/session. Hiding
  is **not locking**: decrypted authority stays in memory and sync continues.
  Lock the OS session when leaving the device. Use **Sign out** to revoke the
  local key handle; use **Quit NNTDrive** to drain and exit. Quit preserves the
  existing password-wrapped login settings, never an unlocked handle/password.
- Pause is the existing persisted user preference, not cancellation. Running
  operations finish. Quit/sign-out permanently stop both initial and periodic
  timers, reject new work and wait for admitted sync/conflict/file operations
  (including terminal native progress callbacks), then lock keys. Shutdown can
  take as long as active I/O; no timeout frees a key/callback early. File pickers
  and confirmation dialogs do not hold the drain open; late submissions fail
  closed. Sign-out pops stale sync routes before allowing another account.
- A support-directory `desktop-session.lock` is held before preferences load.
  Another process cannot unlock or open journals under those settings. Never
  delete/replace this file while an owner may live. GTK's application bus and a
  Windows session-local named mutex additionally activate an existing window on
  normal relaunch. Startup races/missing desktop bus/lock failures fail visibly
  without starting another sync session. Different support directories and older
  versions are not protected by this application lock; per-journal leases still
  apply. Use only local support/journal filesystems.
- `window_manager` **0.5.2** and `tray_manager` **0.5.3** are pinned to their
  platform-plugin releases (published July/June 2026). The existing client had no
  tray/window dependency. These LeanFlutter plugins use native window APIs and
  Ayatana AppIndicator on Linux; adopting their newer `nativeapi` API migration
  is deliberately separate. Lockfile records transitive dependencies/checksums.
- Windows checks the actual tray-icon bounds before hiding. Linux requires an
  active `org.kde.StatusNotifierWatcher` with a registered host on the session
  bus; without a compatible panel/extension, close drains and quits. Successful
  icon/menu setup alone is not treated as proof of a Linux tray. A two-second
  watchdog restores a hidden window after host loss. Menu/setup/hide failures
  never intentionally leave a hidden app with no restore path. Runtime desktops
  still need manual acceptance below (including panel/shell restart).
- Linux builds require `libayatana-appindicator3-dev`; installed bundles require
  its runtime library and a working tray host (e.g. an AppIndicator-enabled
  desktop panel). macOS/mobile close behavior is unchanged. No OS login entry,
  service, worker, password/key store or background permission is registered.

## Remaining background-service scope

### Desktop (Windows and Linux)

1. Validate the implemented per-settings-directory owner and native relaunch
   activation on installed Windows/Linux builds, including simultaneous startup.
   Settings ownership must precede settings/journal access.
2. Explicit opt-in start-at-login using the installed executable's stable path,
   with platform-correct quoting, disable/removal and visible registration errors.
   Start locked after login/restart; do not silently change the vault policy.
3. Validate close/restore, status, Pause/Resume, Quit and tray-host loss with an
   actual panel/shell. The implemented hide path must retain the existing
   controller without a second journal namespace or scheduler.
4. Validate drain-before-lock on quit/sign-out with real active transfers.
   `key()` clones the master key for a running native request: registry revocation
   alone cannot cancel it. Keep callback lifetimes until terminal completion.
5. Keep the folder ID journal path and remote-hash sidecar unchanged. SQLite's
   serialized individual writes are not a whole-sync-operation ownership lock:
   two processes could scan the same baseline and publish conflicting actions.
   Protect complete sync and conflict-resolution runs, not just SQL statements.
   Reject concurrent owners visibly; recover an OS-held lock after process death.

### Android (best effort, not continuous service)

WorkManager can schedule unique periodic work (minimum interval 15 minutes) with
network constraints. OS scheduling is inexact: Doze, battery restrictions,
background limits and vendor policies can delay work; force-stop prevents normal
background execution until the user relaunches. Do not promise five-minute or
continuous mobile synchronization or bypass restrictions with a hidden service.

A cold-start Worker cannot use the UI process's FFI handle. Until an approved
unlock policy exists it must record a bounded `paused: vault locked` result and
request user unlock, **not** retry credentials indefinitely or report sync success.
A live unlocked-process bridge could do best-effort work while that process is
available, but needs explicit native/Flutter ownership and shutdown handling.
Persist only non-secret status/reason/time and non-secret scheduling settings;
never put tokens or key material in WorkManager input/output data or logs.

Use unique work names plus a shared whole-run lock and the existing journal paths.
Cancel/replace work on sign-out or account changes; workers must revalidate the
current account and paused/exclusion state before touching files. Display
`paused by user`, `vault locked`, `waiting for OS/network`, `running` and errors
truthfully. Do not infer a specific OS pause cause from elapsed time alone.
Android directory access / process-restart persistence must be verified on a
real emulator/device, not inferred from desktop path-provider tests.

## Whole-operation exclusion implemented

`SyncEngine::run_once` and `resolve_conflict` acquire `Journal::acquire_operation`
before reading a baseline, snapshotting remote state or touching local files.
A separate `<journal>.operation-lock.sqlite` database holds a SQLite
`BEGIN IMMEDIATE` transaction for the entire operation, independent of the
baseline's short transactions. Another process/Journal instance gets a visible
busy error after a bounded wait: SQLite allows 100 ms for a previous owner's
asynchronous rollback, and the connection/transaction acquisition has a 250 ms
outer deadline. Different journals do not share a global lock.
No credentials or sync content are stored in this sidecar. Keep it in place:
**never delete a lock sidecar while any owner might be running**.

Drop, task cancellation and process death release the lease without modifying
the existing baseline. Linux regressions cover independent owners, both engine
entry points, baseline writes under the lease, cancellation, and a real child
process killed while owning the lease. The engine regression fails without the
entry-point acquisitions. This is not installed Windows/Android acceptance.
The ignored subprocess helper is invoked explicitly by the process-death test,
not a skipped acceptance check.

This protects cooperating updated engines using the **same journal path on a
local filesystem**. It is not a global application single-instance lock: two
configurations pointing the same sync root at different journals are not detected,
and older clients do not participate. Do not run mixed-version owners, place the
journal/sidecar on a network filesystem, or rename/delete them while syncing.
The application now has a per-settings-directory process owner; global root
ownership across different settings/journal mappings remains outside that lock.
Independent background schedulers must share this ownership and the stable
per-folder journal mapping.

## Verification of the same-process increment

On the uncommitted increment over `fe07f15861e5149ecbbe2021b7d1f902a3f9b44b`:

- `bash scripts/dev-check.sh build`: exit 0, adds Ayatana only to the container.
- `bash scripts/dev-check.sh all`: exit 0; formatting/check/Clippy, real
  PostgreSQL/no DB skips, **98 Rust passes** (one enumerated subprocess helper
  ignored, exercised by its process-death parent), release FFI, clean Flutter
  analysis, **39 Flutter passes / 3 existing Windows-only skips**.
- `bash scripts/dev-check.sh flutter-exec bash -ec 'mkdir -p linux/lib; cp
  /target/release/libnntdrive_ffi.so linux/lib/libnntdrive_ffi.so; flutter build
  linux --release --no-pub; test -f
  build/linux/x64/release/bundle/lib/libnntdrive_ffi.so; ldd
  build/linux/x64/release/bundle/nntdrive; ldd
  build/linux/x64/release/bundle/lib/libnntdrive_ffi.so'`: exit 0; native tray/window
  plugins and Rust library bundled; no missing dynamic libraries. This is a
  **build/link** check, not a GUI or tray-panel test.
- `python3 scripts/test-dev-check.py`, `python3 scripts/test-ci-contracts.py`,
  `python3 scripts/test-workflow-performance.py`,
  `python3 scripts/test-agent-policy.py`: 5/5/4/7 passes; Bash syntax and
  `git diff --check` pass. The custom wrapper command retains the same
  worktree lock, internal-only service and automatic cleanup.

## Required evidence before #6 is complete

- `cargo test -p nntdrive-sync` and affected FFI/Flutter suites.
- Windows and Linux: real installed app, unlocked two-device transfer after close;
  tray restore; explicit pause/resume; quit; opt-in login restart (locked state
  shown); unlock then transfer; autostart removal and bad-path errors.
- Race two launches and foreground/background runs: one owner, same journals,
  no duplicate upload/actions; kill owner and verify safe restart with baseline
  preserved. Include concurrent conflict resolution and account switch/sign-out.
- Android: actual WorkManager execution with a live session and cold process;
  unique scheduling, network/battery/Doze delays, force-stop/relaunch, cancellation,
  folder access and visible paused status. A packaged APK is not runtime evidence.
- Decide whether acceptance permits **restart locked, resume after user unlock**.
  If unattended cold-login sync is mandatory, approve a separate secure device-key
  design first. Do not quietly add #7/#50 or weaken password-required unlocking.

Automated tests exercise close/restore and tray-loss/error policy through a fake
host; no-drain-on-hide; quit ordering/idempotence; failed and successful operation
draining; timer cancellation/late startup; real child-process settings-lock
exclusion/kill recovery; native async admission after drain; and real-FFI widget
unlock, controller reuse and sign-out lock ordering. These are not installed
platform acceptance. The Linux release bundle builds in the repository container.
No Windows GUI/build, live Linux tray/panel, Android runtime, autostart or
WorkManager acceptance is claimed. #6 remains incomplete.
