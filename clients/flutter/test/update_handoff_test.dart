import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/update_handoff.dart';

void main() {
  test('handoff waits for both launch and acknowledgement before app may exit', () async {
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
    await expectLater(startUpdateHelper(
        () => Future<Process>.error(const ProcessException('missing-helper', [])),
        () async { acknowledged = true; }), throwsA(isA<ProcessException>()));
    expect(acknowledged, isFalse);
  });

  test('missing helper acknowledgement cancels, never authorizes exit', () async {
    final state = await Directory.systemTemp.createTemp('handoff-test-');
    addTearDown(() => state.delete(recursive: true));
    await expectLater(waitForWindowsHelper(state, timeout: Duration.zero), throwsStateError);
    expect(File('${state.path}/cancel').existsSync(), isTrue);
  });

  test('failure wins over readiness; success needs explicit ready marker', () async {
    final state = await Directory.systemTemp.createTemp('handoff-test-');
    addTearDown(() => state.delete(recursive: true));
    File('${state.path}/ready').writeAsStringSync('ready');
    await waitForWindowsHelper(state);
    File('${state.path}/failed').writeAsStringSync('preflight');
    await expectLater(waitForWindowsHelper(state), throwsStateError);
  });

  test('Windows paths are literals and helpers retain recoverable failure state', () {
    final script = windowsUpdateScript(stage: r"C:\O'Brien & sons\$stage", install: r'C:\app (test)', state: r'C:\temp\state', parentPid: 123);
    expect(script, contains(r"$stage = 'C:\O''Brien & sons\$stage'"));
    expect(script, contains('Get-Process -Id 123'));
    expect(script, contains("Record 'complete'"));
    expect(script, contains("\$step = 'backup'"));
    expect(script, contains('Get-FileHash -LiteralPath'));
    expect(script, isNot(contains('Remove-Item -LiteralPath \$stage')));
    expect(script, isNot(contains('ExecutionPolicy')));
  });

  test('Windows helper replaces payload, preserves data and restarts', () async {
    final root = await Directory.systemTemp.createTemp("handoff O'Brien & replace-");
    addTearDown(() => root.delete(recursive: true));
    final stage = await Directory('${root.path}/stage').create();
    final install = await Directory('${root.path}/install').create();
    final state = await Directory('${root.path}/state').create();
    // A real short-lived child provides a parent PID without exiting the test.
    final parent = await Process.start('cmd.exe', ['/c', 'exit', '0']);
    await parent.exitCode;
    File('${stage.path}/launch.cmd').writeAsStringSync('@echo off\r\necho new>"%~dp0restarted"\r\n');
    File('${stage.path}/payload').writeAsStringSync('new');
    File('${install.path}/payload').writeAsStringSync('old');
    File('${install.path}/journal').writeAsStringSync('preserve');
    final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', windowsUpdateScript(stage: stage.path, install: install.path, state: state.path, parentPid: parent.pid, executable: 'launch.cmd', showFailureDialog: false)]);
    final diagnostic = File('${state.path}/update.log');
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}\n${diagnostic.existsSync() ? diagnostic.readAsStringSync() : "no helper log"}');
    expect(File('${state.path}/complete').existsSync(), isTrue);
    expect(File('${state.path}/backup/payload').readAsStringSync(), 'old');
    expect(File('${install.path}/payload').readAsStringSync(), 'new');
    expect(File('${install.path}/journal').readAsStringSync(), 'preserve');
    for (var i = 0; i < 50 && !File('${install.path}/restarted').existsSync(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(File('${install.path}/restarted').readAsStringSync().trim(), 'new');
  }, skip: !Platform.isWindows);

  test('Windows helper parses and rejects an invalid staged layout before exit', () async {
    final root = await Directory.systemTemp.createTemp("handoff O'Brien & test-");
    addTearDown(() => root.delete(recursive: true));
    final stage = await Directory('${root.path}/stage').create();
    final install = await Directory('${root.path}/install').create();
    final state = await Directory('${root.path}/state').create();
    File('${install.path}/sentinel').writeAsStringSync('unchanged');
    final script = windowsUpdateScript(stage: stage.path, install: install.path, state: state.path, parentPid: pid);
    final result = await Process.run('powershell.exe', ['-NoProfile', '-NonInteractive', '-Command', script]);
    expect(result.exitCode, 1, reason: '${result.stdout}\n${result.stderr}');
    expect(File('${state.path}/failed').readAsStringSync(), 'preflight');
    expect(File('${state.path}/ready').existsSync(), isFalse);
    expect(File('${install.path}/sentinel').readAsStringSync(), 'unchanged');
    expect(File('${state.path}/update.log').readAsStringSync(), contains('no application at its root'));
  }, skip: !Platform.isWindows);
}
