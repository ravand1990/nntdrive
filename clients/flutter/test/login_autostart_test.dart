import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/login_autostart.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('nntdrive-autostart-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  group('desktop entry', () {
    test('quotes a plain path', () {
      expect(
        desktopEntryExec('/opt/nntdrive/nntdrive'),
        '"/opt/nntdrive/nntdrive"',
      );
    });

    test('keeps a path with spaces as one argument', () {
      expect(desktopEntryExec('/home/a b/NNT Drive'), '"/home/a b/NNT Drive"');
    });

    test('escapes reserved characters and field codes', () {
      expect(
        desktopEntryExec(r'/tmp/we"ird`$dir\bin%f'),
        r'"/tmp/we\"ird\`\$dir\\bin%%f"',
      );
    });

    test('writes a desktop entry naming the executable', () {
      final entry = desktopEntry('/usr/bin/nntdrive');
      expect(entry, contains('[Desktop Entry]'));
      expect(entry, contains('Type=Application'));
      expect(entry, contains('Exec="/usr/bin/nntdrive"'));
      expect(entry, contains('Terminal=false'));
    });
  });

  group('linux', () {
    test('enable writes the entry and disable removes it', () async {
      final autostart = LinuxLoginAutostart(autostartDirectory: root);
      final file = File(p.join(root.path, LinuxLoginAutostart.fileName));

      await autostart.apply(enabled: true, executable: '/opt/app/nntdrive');
      expect(await file.exists(), isTrue);
      expect(await file.readAsString(), contains('Exec="/opt/app/nntdrive"'));

      await autostart.apply(enabled: false, executable: '/opt/app/nntdrive');
      expect(await file.exists(), isFalse);
    });

    test('creates the autostart directory when missing', () async {
      final nested = Directory(p.join(root.path, 'config', 'autostart'));
      final autostart = LinuxLoginAutostart(autostartDirectory: nested);
      await autostart.apply(enabled: true, executable: '/opt/app/nntdrive');
      expect(
        await File(p.join(nested.path, LinuxLoginAutostart.fileName)).exists(),
        isTrue,
      );
    });

    test('disable without an entry succeeds', () async {
      final autostart = LinuxLoginAutostart(autostartDirectory: root);
      await autostart.apply(enabled: false, executable: '/opt/app/nntdrive');
    });

    test('enable without an executable fails and writes nothing', () async {
      final autostart = LinuxLoginAutostart(autostartDirectory: root);
      await expectLater(
        autostart.apply(enabled: true, executable: '   '),
        throwsA(isA<LoginAutostartException>()),
      );
      expect(
        await File(p.join(root.path, LinuxLoginAutostart.fileName)).exists(),
        isFalse,
      );
    });

    test('prefers XDG_CONFIG_HOME over HOME', () {
      final autostart = LinuxLoginAutostart(
        environment: {'XDG_CONFIG_HOME': '/xdg', 'HOME': '/home/person'},
      );
      expect(autostart.directory.path, p.join('/xdg', 'autostart'));
    });

    test('falls back to HOME and refuses to guess without it', () {
      expect(
        LinuxLoginAutostart(
          environment: {'HOME': '/home/person'},
        ).directory.path,
        p.join('/home/person', '.config', 'autostart'),
      );
      expect(
        () => LinuxLoginAutostart(
          environment: {'XDG_CONFIG_HOME': '  '},
        ).directory,
        throwsA(isA<LoginAutostartException>()),
      );
    });
  });

  group('windows', () {
    late List<(String, List<String>)> calls;
    late int exitCode;
    late String stderrText;

    WindowsLoginAutostart build() => WindowsLoginAutostart(
      runProcess: (executable, arguments) async {
        calls.add((executable, arguments));
        return ProcessResult(1, exitCode, '', stderrText);
      },
    );

    setUp(() {
      calls = [];
      exitCode = 0;
      stderrText = '';
    });

    test('enable writes the per-user Run value', () async {
      await build().apply(
        enabled: true,
        executable: r'C:\Program Files\NNTDrive\nntdrive.exe',
      );
      expect(calls, hasLength(1));
      expect(calls.single.$1, 'reg.exe');
      expect(calls.single.$2, [
        'add',
        WindowsLoginAutostart.runKey,
        '/v',
        WindowsLoginAutostart.valueName,
        '/t',
        'REG_SZ',
        '/d',
        r'C:\Program Files\NNTDrive\nntdrive.exe',
        '/f',
      ]);
    });

    test('disable removes the Run value', () async {
      await build().apply(enabled: false, executable: 'ignored');
      expect(calls.single.$2, [
        'delete',
        WindowsLoginAutostart.runKey,
        '/v',
        WindowsLoginAutostart.valueName,
        '/f',
      ]);
    });

    test('a failed enable surfaces the first error line', () async {
      exitCode = 2;
      stderrText = 'ERROR: Access is denied.\nmore detail';
      await expectLater(
        build().apply(enabled: true, executable: r'C:\app\nntdrive.exe'),
        throwsA(
          isA<LoginAutostartException>().having(
            (e) => e.message,
            'message',
            contains('Access is denied'),
          ),
        ),
      );
    });

    test('deleting an absent value is not an error', () async {
      exitCode = 1;
      await build().apply(enabled: false, executable: 'ignored');
    });

    test('enable without an executable never touches the registry', () async {
      await expectLater(
        build().apply(enabled: true, executable: ''),
        throwsA(isA<LoginAutostartException>()),
      );
      expect(calls, isEmpty);
    });
  });

  group('platform selection', () {
    test('linux and windows are supported', () {
      expect(
        platformLoginAutostart(operatingSystem: 'linux').supported,
        isTrue,
      );
      expect(
        platformLoginAutostart(operatingSystem: 'windows').supported,
        isTrue,
      );
    });

    test('other platforms report unsupported and refuse to enable', () async {
      final autostart = platformLoginAutostart(operatingSystem: 'android');
      expect(autostart.supported, isFalse);
      await expectLater(
        autostart.apply(enabled: true, executable: '/data/app'),
        throwsA(isA<LoginAutostartException>()),
      );
      // Disabling stays a no-op so a copied preference cannot break startup.
      await autostart.apply(enabled: false, executable: '/data/app');
    });
  });
}
