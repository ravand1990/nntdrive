import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/update_handoff.dart';

void main() {
  test('handoff waits for both launch and acknowledgement before app may exit',
      () async {
    final launch = Completer<Process>();
    final ready = Completer<void>();
    var acknowledged = false;
    var done = false;
    final handoff = startUpdateHelper(() => launch.future, () {
      acknowledged = true;
      return ready.future;
    }).then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse);
    expect(acknowledged, isFalse);
    final process = await Process.start(
        Platform.isWindows ? 'cmd.exe' : '/bin/sh',
        Platform.isWindows ? ['/c', 'exit', '0'] : ['-c', 'exit 0']);
    launch.complete(process);
    await Future<void>.delayed(Duration.zero);
    expect(acknowledged, isTrue);
    expect(done, isFalse);
    ready.complete();
    await handoff;
    await process.exitCode;
    expect(done, isTrue);
  });

  test('launch errors reach the UI instead of allowing exit', () async {
    var acknowledged = false;
    await expectLater(
        startUpdateHelper(
            () => Future<Process>.error(
                const ProcessException('missing-helper', [])), () async {
          acknowledged = true;
        }),
        throwsA(isA<ProcessException>()));
    expect(acknowledged, isFalse);
  });

  test('missing helper acknowledgement cancels, never authorizes exit',
      () async {
    final state = await Directory.systemTemp.createTemp('handoff-test-');
    addTearDown(() => state.delete(recursive: true));
    await expectLater(
        waitForWindowsHelper(state, timeout: Duration.zero), throwsStateError);
    expect(File('${state.path}/cancel').existsSync(), isTrue);
  });

  test('failure wins over readiness; success needs explicit ready marker',
      () async {
    final state = await Directory.systemTemp.createTemp('handoff-test-');
    addTearDown(() => state.delete(recursive: true));
    File('${state.path}/ready').writeAsStringSync('ready');
    await waitForWindowsHelper(state);
    File('${state.path}/failed').writeAsStringSync('preflight');
    await expectLater(waitForWindowsHelper(state), throwsStateError);
  });

  test(
      'Windows paths are literals and helpers retain recoverable failure state',
      () {
    final script = windowsUpdateScript(
        stage: r"C:\O'Brien & sons\$stage",
        install: r'C:\app (test)',
        state: r'C:\temp\state',
        parentPid: 123);
    expect(script, contains(r"$stage = 'C:\O''Brien & sons\$stage'"));
    expect(script, contains('Get-Process -Id 123'));
    expect(script, contains("Record 'complete'"));
    expect(script, contains("\$step = 'backup'"));
    expect(script, contains('[Security.Cryptography.SHA256]::Create()'));
    expect(script, contains('if ((Hash \$target) -ne (Hash \$file.FullName))'));
    expect(script, isNot(contains('Remove-Item -LiteralPath \$stage')));
    expect(script, isNot(contains('ExecutionPolicy')));
  });

  test('Windows helper replaces payload, preserves data and restarts',
      () async {
    final root =
        await Directory.systemTemp.createTemp("handoff O'Brien & replace-");
    addTearDown(() => root.delete(recursive: true));
    final stage = await Directory('${root.path}/stage').create();
    final install = await Directory('${root.path}/install').create();
    final state = await Directory('${root.path}/state').create();
    // A real short-lived child provides a parent PID without exiting the test.
    final parent = await Process.start('cmd.exe', ['/c', 'exit', '0']);
    await parent.exitCode;
    // Use an actual PE executable, matching production rather than relying on
    // .cmd shell associations (which are absent on some headless runners).
    File('${Platform.environment['SystemRoot']}/System32/where.exe')
        .copySync('${stage.path}/nntdrive.exe');
    File('${stage.path}/payload').writeAsStringSync('new');
    File('${install.path}/payload').writeAsStringSync('old');
    File('${install.path}/journal').writeAsStringSync('preserve');
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      windowsUpdateScript(
          stage: stage.path,
          install: install.path,
          state: state.path,
          parentPid: parent.pid,
          showFailureDialog: false)
    ]);
    final diagnostic = File('${state.path}/update.log');
    expect(result.exitCode, 0,
        reason:
            '${result.stdout}\n${result.stderr}\n${diagnostic.existsSync() ? diagnostic.readAsStringSync() : "no helper log"}');
    expect(File('${state.path}/complete').existsSync(), isTrue);
    expect(File('${state.path}/backup/payload').readAsStringSync(), 'old');
    expect(File('${install.path}/payload').readAsStringSync(), 'new');
    expect(File('${install.path}/journal').readAsStringSync(), 'preserve');
    expect(File('${install.path}/nntdrive.exe').readAsBytesSync(),
        File('${stage.path}/nntdrive.exe').readAsBytesSync());
    expect(diagnostic.readAsStringSync(), contains('complete'));
  }, skip: !Platform.isWindows);

  test(
      'detached Windows helper survives its real installed parent and restarts',
      () async {
    final root =
        await Directory.systemTemp.createTemp("detached O'Brien & update-");
    Process? parent;
    int? restartedPid;
    addTearDown(() async {
      // Stop the exact detached helper before killing its parent: otherwise
      // teardown itself could authorize replacement/restart during deletion.
      for (final entry in root.listSync().whereType<Directory>()) {
        if (!entry.path.contains('nntdrive-update-handoff-')) continue;
        File('${entry.path}/cancel').writeAsStringSync('cancel');
        final helperMarker = File('${entry.path}/helper-pid');
        if (helperMarker.existsSync()) {
          final helperPid = int.parse(helperMarker.readAsStringSync());
          await Process.run('taskkill', [
            '/PID',
            '$helperPid',
            '/T',
            '/F',
            '/FI',
            'IMAGENAME eq powershell.exe',
          ]);
        }
      }
      parent?.kill();
      if (parent != null) await parent.exitCode;
      final restartMarker = File('${root.path}/install/restarted-pid');
      if (restartMarker.existsSync()) {
        restartedPid = int.parse(restartMarker.readAsStringSync());
      }
      if (restartedPid != null) {
        await Process.run('taskkill', [
          '/PID',
          '$restartedPid',
          '/F',
          '/FI',
          'IMAGENAME eq nntdrive.exe',
        ]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await root.delete(recursive: true);
    });
    final install = await Directory('${root.path}/install').create();
    final stage = await Directory('${root.path}/stage').create();
    final executable = File('${install.path}/nntdrive.exe');
    // flutter-action puts the actual Dart SDK on PATH. Compile a real PE so the
    // running parent locks the installed executable just as the desktop app does.
    final dart =
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/dart-sdk/bin/dart.exe';
    expect(File(dart).existsSync(), isTrue,
        reason: 'A real Dart SDK is required');
    final compiled = await Process.run(dart, [
      'compile',
      'exe',
      'test/fixtures/update_parent_probe.dart',
      '-o',
      executable.path,
    ]);
    expect(compiled.exitCode, 0,
        reason: '${compiled.stdout}\n${compiled.stderr}');
    await executable.copy('${stage.path}/nntdrive.exe');
    File('${stage.path}/payload').writeAsStringSync('new');
    File('${install.path}/payload').writeAsStringSync('old');
    File('${install.path}/journal').writeAsStringSync('preserve');
    parent = await Process.start(executable.path, [stage.path, install.path]);
    final stderr =
        parent.stderr.transform(const SystemEncoding().decoder).join();
    final stdout =
        parent.stdout.transform(const SystemEncoding().decoder).join();
    final parentExit =
        await parent.exitCode.timeout(const Duration(seconds: 25));
    final startupLogs = root
        .listSync()
        .whereType<Directory>()
        .expand((dir) => ['update.log', 'helper-stderr.log']
            .map((name) => File('${dir.path}/$name')))
        .where((file) => file.existsSync())
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(parentExit, 0,
        reason: '${await stdout}\n${await stderr}\n$startupLogs');
    final statePath = File('${install.path}/handoff-state').readAsStringSync();
    final watch = Stopwatch()..start();
    final marker = File('${install.path}/restarted-pid');
    while (watch.elapsed < const Duration(seconds: 30)) {
      if (marker.existsSync()) {
        restartedPid = int.parse(marker.readAsStringSync());
      }
      if (File('$statePath/complete').existsSync() && restartedPid != null) {
        break;
      }
      if (File('$statePath/failed').existsSync()) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final log = File('$statePath/update.log').readAsStringSync();
    expect(File('$statePath/failed').existsSync(), isFalse, reason: log);
    expect(File('$statePath/complete').existsSync(), isTrue, reason: log);
    expect(restartedPid, isNotNull, reason: log);
    expect(restartedPid, isNot(parent.pid));
    expect(File('${install.path}/payload').readAsStringSync(), 'new');
    expect(File('$statePath/backup/payload').readAsStringSync(), 'old');
    expect(File('${install.path}/journal').readAsStringSync(), 'preserve');
    expect(await executable.readAsBytes(),
        await File('${stage.path}/nntdrive.exe').readAsBytes());
  }, skip: !Platform.isWindows, timeout: const Timeout(Duration(minutes: 2)));

  test('rollback removal errors are terminating and verified before restart',
      () {
    final script = windowsUpdateScript(
        stage: 'stage', install: 'install', state: 'state', parentPid: 123);
    expect(script,
        contains(r'Remove-Item -LiteralPath $target -Force -ErrorAction Stop'));
    expect(
        script,
        contains(
            r"if (Test-Path -LiteralPath $target) { throw 'Rollback file removal failed.' }"));
  });

  test('Windows rollback deletion failure does not restart a mixed install',
      () async {
    final root = await Directory.systemTemp.createTemp('handoff-rollback-');
    addTearDown(() => root.delete(recursive: true));
    final stage = await Directory('${root.path}/stage').create();
    final install = await Directory('${root.path}/install').create();
    final state = await Directory('${root.path}/state').create();
    File('${stage.path}/nntdrive.exe').writeAsStringSync('new payload');
    final parent = await Process.start('cmd.exe', ['/c', 'exit', '0']);
    await parent.exitCode;
    // Deterministic fault injection: fail after replacement, simulate a sharing
    // lock on rollback deletion, and record any attempted application restart.
    final script = windowsUpdateScript(
            stage: stage.path,
            install: install.path,
            state: state.path,
            parentPid: parent.pid,
            showFailureDialog: false)
        .replaceFirst(r"$step = 'restart'",
            "throw 'injected replacement failure'\n\$step = 'restart'");
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      r'''
function Remove-Item {
  param($LiteralPath, [switch]$Force, $ErrorAction)
  if ($LiteralPath.EndsWith('nntdrive.exe')) {
    Write-Error 'injected sharing lock' -ErrorAction $ErrorAction
    return
  }
  Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Force:$Force
}
function Start-Process {
  param($FilePath, $WorkingDirectory, $ErrorAction)
  [IO.File]::WriteAllText((Join-Path $WorkingDirectory 'restart-attempted'), 'yes')
}
''' +
          script
    ]);
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    expect(File('${state.path}/update.log').readAsStringSync(),
        contains('rollback failed; preserve backup'));
    expect(File('${install.path}/restart-attempted').existsSync(), isFalse);
    expect(File('${install.path}/nntdrive.exe').existsSync(), isTrue);
    expect(File('${state.path}/complete').existsSync(), isFalse);
  }, skip: !Platform.isWindows);

  test('Windows helper parses and rejects an invalid staged layout before exit',
      () async {
    final root =
        await Directory.systemTemp.createTemp("handoff O'Brien & test-");
    addTearDown(() => root.delete(recursive: true));
    final stage = await Directory('${root.path}/stage').create();
    final install = await Directory('${root.path}/install').create();
    final state = await Directory('${root.path}/state').create();
    File('${install.path}/sentinel').writeAsStringSync('unchanged');
    final script = windowsUpdateScript(
        stage: stage.path,
        install: install.path,
        state: state.path,
        parentPid: pid);
    final result = await Process.run('powershell.exe',
        ['-NoProfile', '-NonInteractive', '-Command', script]);
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    expect(File('${state.path}/failed').readAsStringSync(), 'preflight');
    expect(File('${state.path}/ready').existsSync(), isFalse);
    expect(File('${install.path}/sentinel').readAsStringSync(), 'unchanged');
    expect(File('${state.path}/update.log').readAsStringSync(),
        contains('no application at its root'));
  }, skip: !Platform.isWindows);
}
