# Background sync feasibility and security boundary (NNT-001 / #6)

## Delivery status

This is a **partial implementation / design handoff**, not a background service.
The unlock screen now explains that sync is paused while the vault is locked.
Native regression tests exercise every sync entry point with a missing or
revoked process-local key handle, checking rejection before journal creation or
backend contact. Whole sync rounds and conflict resolution now hold an exclusive
SQLite operation lease for their journal; competing owners fail visibly rather
than scanning and publishing from the same baseline. Desktop tray/autostart and
Android WorkManager are not installed or registered by this change. Closing the
current desktop window still ends sync.

## What prevents unattended cold-start sync today

- `clients/flutter/lib/main.dart` restores the token and **password-wrapped**
  keyfile, then shows `UnlockPage`. `_completeAuth` requires the password and
  calls `NativeBridge.unlockAsync`. Persisting a token is not a decryption grant.
- `crates/ffi/src/lib.rs` stores master keys only in the process-local `HANDLES`
  table. `key(handle)` rejects missing/revoked handles. Each sync entry point
  checks this before opening its journal or making remote requests. An integer
  saved by Dart cannot restore the key after process death or in another process.
- `SyncController` owns a five-minute Dart timer under `FilesPage`. There is no
  durable worker, interprocess session transport, or lifecycle-independent owner.
  Hiding a window could retain an already-unlocked process; restarting it cannot.
- Moving the password-wrapped keyfile into an OS key store (#7) alone does **not**
  unlock it. Automatic unlock would require a separately approved device-key /
  OS-unlock policy. Password remembering (#50) is outside #6 and this change.

Never persist a plaintext password, AMK, or a serialized unlocked handle, pass a
key on a command line, or send it to the backend to satisfy login resumption.
Autostart can safely launch **locked**, visibly requiring user unlock. It cannot
honestly promise automatic encrypted sync after login with today's key policy.
This is a security constraint on cold starts, not a claim that close-to-tray is
impossible while the unlocked process remains alive.

## Smallest safe implementation to finish

### Desktop (Windows and Linux)

1. One per-user application/session owner with an OS-held single-instance lock;
   subsequent launches activate its window rather than start another controller.
   Acquire ownership before reading/writing sync settings or opening journals.
2. Explicit opt-in start-at-login using the installed executable's stable path,
   with platform-correct quoting, disable/removal and visible registration errors.
   Start locked after login/restart; do not silently change the vault policy.
3. Close hides the window only when a working tray restore/quit path exists.
   Tray exposes Open, sync state, Pause/Resume and Quit. An unsupported tray must
   not strand an invisible process. Keep the existing controller alive on hide;
   do not create a second journal namespace or second scheduler.
4. Quit/sign-out stop scheduling, drain native operations, then lock/release keys.
   `key()` currently clones the master key for a running native request: locking
   its registry entry does not cancel an already-started operation. Do not claim
   immediate cancellation or free callback lifetimes early.
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
Application ownership and stable per-folder journal mapping are still required
before adding independent background schedulers.

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

The current change supplies no Windows, Linux GUI, Android runtime, tray,
autostart, application-wide duplicate-worker exclusion or WorkManager evidence.
The per-journal operation regressions above are narrower than application/session
ownership. See the task handoff for exact executed check commands; passing unit
tests is not platform acceptance.
