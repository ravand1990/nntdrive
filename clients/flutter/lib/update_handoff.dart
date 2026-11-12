import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// PowerShell -EncodedCommand expects UTF-16LE, not UTF-8. Avoid the native
/// command-line parser interpreting the script's quotes or multiline syntax.
String encodePowerShellCommand(String source) => base64Encode([
      for (final unit in source.codeUnits) ...[unit & 0xff, unit >> 8],
    ]);

/// Do not let the UI exit until the detached process actually exists. A bare
/// Process.start future can be abandoned by exit(0), also hiding launch errors.
Future<void> startUpdateHelper(Future<Process> Function() launch,
    Future<void> Function() acknowledge) async {
  await launch();
  await acknowledge();
}

/// Launch exactly the same detached helper from the app and the real-process
/// regression probe. The returned directory contains diagnostics, not secrets.
Future<Directory> launchWindowsUpdateHelper({
  required Directory stage,
  required String install,
  required int parentPid,
  bool showFailureDialog = true,
}) async {
  final state = await stage.parent.createTemp('nntdrive-update-handoff-');
  final source = windowsUpdateScript(
    stage: stage.path,
    install: install,
    state: state.path,
    parentPid: parentPid,
    showFailureDialog: showFailureDialog,
  );
  // Retain the exact script. Do not modify machine execution policy.
  await File('${state.path}/update.ps1').writeAsString('\ufeff$source');
  await startUpdateHelper(
    () async {
      final helper = await Process.start(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-EncodedCommand',
          encodePowerShellCommand(source)
        ],
        // Use ordinary Windows process creation: PowerShell does not reach
        // preflight with Dart's detached creation flags. The app explicitly
        // exits after acknowledgement; the OS child continues independently.
        mode: ProcessStartMode.normal,
      );
      // No input is ever sent to the helper. Close the pipe so PowerShell
      // cannot wait for input/EOF before executing a redirected invocation.
      await helper.stdin.close();
      // Drain startup output while the app lives; do not await helper exit.
      // The script itself retains all post-exit diagnostics in update.log.
      helper.stdout.listen((_) {}, onError: (Object _) {});
      helper.stderr.listen((bytes) {
        try {
          File('${state.path}/helper-stderr.log')
              .writeAsBytesSync(bytes, mode: FileMode.append);
        } on FileSystemException catch (_) {
          // A diagnostic write must not interrupt the acknowledgement wait.
        }
      }, onError: (Object _) {});
      // Retain the exact launched PID for diagnostics and bounded fixture cleanup.
      final marker = File('${state.path}/helper-pid.tmp');
      await marker.writeAsString('${helper.pid}');
      await marker.rename('${state.path}/helper-pid');
      return helper;
    },
    () => waitForWindowsHelper(state),
  );
  return state;
}

/// Windows PowerShell single-quoted strings do not interpolate paths or IDs.
String _literal(String value) => "'${value.replaceAll("'", "''")}'";

/// The helper acknowledges preflight before the caller exits. Keep diagnostic
/// files outside the payload; failed replacement preserves the stage and backup.
String windowsUpdateScript({
  required String stage,
  required String install,
  required String state,
  required int parentPid,
  String executable = 'nntdrive.exe',
  bool showFailureDialog = true,
}) =>
    '''
\$ErrorActionPreference = 'Stop'
\$stage = ${_literal(stage)}
\$install = ${_literal(install)}
\$state = ${_literal(state)}
\$exe = ${_literal(executable)}
\$step = 'preflight'
\$changed = @()
\$backed = @()
\$backup = Join-Path \$state 'backup'
function Record([string]\$message) {
  Add-Content -LiteralPath (Join-Path \$state 'update.log') -Value \$message
}
# Do not depend on Get-FileHash autoloading: a parent launched by PowerShell 7
# can pass a PSModulePath that excludes Windows PowerShell's utility modules.
function Hash([string]\$path) {
  \$stream = [IO.File]::OpenRead(\$path)
  \$hasher = [Security.Cryptography.SHA256]::Create()
  try { return [Convert]::ToBase64String(\$hasher.ComputeHash(\$stream)) }
  finally { \$hasher.Dispose(); \$stream.Dispose() }
}
try {
  Record 'preflight'
  # FileInfo.FullName uses normalized Windows separators/expanded paths; use
  # the same representation when computing payload-relative paths below.
  \$stage = (Get-Item -LiteralPath \$stage).FullName.TrimEnd('\\')
  \$install = (Get-Item -LiteralPath \$install).FullName.TrimEnd('\\')
  if (!(Test-Path -LiteralPath (Join-Path \$stage \$exe) -PathType Leaf)) {
    throw 'The update archive has no application at its root.'
  }
  # Test directory write access before allowing the running app to exit.
  \$probe = Join-Path \$install ([IO.Path]::GetRandomFileName())
  [IO.File]::WriteAllText(\$probe, '')
  Remove-Item -LiteralPath \$probe
  New-Item -ItemType Directory -Path \$backup | Out-Null
  [IO.File]::WriteAllText((Join-Path \$state 'ready'), 'ready')
  \$step = 'wait-for-exit'
  Record \$step
  \$deadline = [DateTime]::UtcNow.AddSeconds(60)
  while (Get-Process -Id $parentPid -ErrorAction SilentlyContinue) {
    if ((Test-Path -LiteralPath (Join-Path \$state 'cancel')) -or [DateTime]::UtcNow -gt \$deadline) {
      throw 'The application did not exit; nothing was replaced.'
    }
    Start-Sleep -Milliseconds 200
  }
  if (Test-Path -LiteralPath (Join-Path \$state 'cancel')) { throw 'Update cancelled.' }
  \$step = 'backup'
  Record \$step
  \$files = @(Get-ChildItem -LiteralPath \$stage -File -Recurse)
  foreach (\$file in \$files) {
    \$relative = \$file.FullName.Substring(\$stage.Length).TrimStart('\\')
    \$target = Join-Path \$install \$relative
    if (Test-Path -LiteralPath \$target) {
      \$saved = Join-Path \$backup \$relative
      New-Item -ItemType Directory -Force -Path (Split-Path \$saved) | Out-Null
      Copy-Item -LiteralPath \$target -Destination \$saved
      \$backed += \$relative
      # Reject locked/read-only payload files before changing any install file.
      \$handle = [IO.File]::Open(\$target, 'Open', 'ReadWrite', 'None')
      \$handle.Dispose()
    }
  }
  \$step = 'replace'
  Record \$step
  foreach (\$file in \$files) {
    \$relative = \$file.FullName.Substring(\$stage.Length).TrimStart('\\')
    \$target = Join-Path \$install \$relative
    New-Item -ItemType Directory -Force -Path (Split-Path \$target) | Out-Null
    \$changed += \$relative
    Copy-Item -LiteralPath \$file.FullName -Destination \$target -Force
    if ((Hash \$target) -ne (Hash \$file.FullName)) {
      throw 'Installed file verification failed.'
    }
  }
  \$step = 'restart'
  Record \$step
  Start-Process -FilePath (Join-Path \$install \$exe) -WorkingDirectory \$install -ErrorAction Stop | Out-Null
  Record 'complete'
  [IO.File]::WriteAllText((Join-Path \$state 'complete'), 'complete')
} catch {
  Record (\$step + ': ' + \$_.Exception.Message)
  [IO.File]::WriteAllText((Join-Path \$state 'failed'), \$step)
  \$rollbackOk = \$true
  foreach (\$relative in \$changed) {
    try {
      \$target = Join-Path \$install \$relative
      if (\$backed -contains \$relative) {
        Copy-Item -LiteralPath (Join-Path \$backup \$relative) -Destination \$target -Force
      } elseif (Test-Path -LiteralPath \$target) {
        Remove-Item -LiteralPath \$target -Force -ErrorAction Stop
        if (Test-Path -LiteralPath \$target) { throw 'Rollback file removal failed.' }
      }
    } catch { \$rollbackOk = \$false; Record 'rollback failed; preserve backup for manual recovery' }
  }
  if (!(Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) {
    if (\$rollbackOk) {
      try { Start-Process -FilePath (Join-Path \$install \$exe) -WorkingDirectory \$install -ErrorAction Stop | Out-Null }
      catch { Record 'restart of previous application failed' }
    }
    # No Flutter process remains to show its error dialog after exit.
    if (${showFailureDialog ? r'$true' : r'$false'}) {
      try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show(('Update failed at ' + \$step + '. Diagnostic and recovery files: ' + \$state), 'NNTDrive update failed') | Out-Null
      } catch { Record 'could not show failure dialog' }
    }
  }
  exit 1
}
''';

Future<void> waitForWindowsHelper(Directory state,
    {Duration timeout = const Duration(seconds: 15)}) async {
  final watch = Stopwatch()..start();
  while (watch.elapsed < timeout) {
    if (File('${state.path}${Platform.pathSeparator}failed').existsSync()) {
      throw StateError(
          'Update helper preflight failed. See ${state.path} for diagnostics; the app has not closed.');
    }
    if (File('${state.path}${Platform.pathSeparator}ready').existsSync()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  File('${state.path}${Platform.pathSeparator}cancel')
      .writeAsStringSync('cancel');
  throw StateError(
      'Update helper did not acknowledge startup. See ${state.path} for diagnostics; the app has not closed.');
}
