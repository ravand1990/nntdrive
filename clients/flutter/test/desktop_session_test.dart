import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/desktop_instance.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('session controller announces completed load and stops equality admission', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sync = SyncController(server: 'http://unused', token: '', handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async => const AccountRootsResult([]));
    addTearDown(sync.dispose);
    final loadedNotifications = <bool>[];
    sync.addListener(() => loadedNotifications.add(sync.loaded));
    expect(sync.loaded, isFalse);
    await sync.load();
    expect(sync.loaded, isTrue);
    expect(loadedNotifications.last, isTrue);
    await sync.stopAndDrain();
    // No platform directory lookup or native core access after stop.
    expect(await sync.fileMatches(SyncFolderConfig(id: 'id', name: 'folder',
      localPath: '/unused', remoteRootId: 'root'), 'file',
      RemoteFile('file', 'root', 'opaque', false, 0, false, 1, 'revision')), isFalse);
  });

  testWidgets(
      'stop cancels initial and recurring timers, including late load/start',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sync = SyncController(
        server: 'http://127.0.0.1:1',
        token: '',
        handle: 0,
        api: ApiClient(baseUrl: 'http://127.0.0.1:1'),
        rootsLoader: () async => const AccountRootsResult([]));
    var notifications = 0;
    sync.addListener(() => notifications++);
    sync.start();
    await sync.stopAndDrain();
    await sync.load();
    sync.start();
    await tester.pump(const Duration(minutes: 6));
    expect(notifications, 0);
    await sync.syncAll();
    expect(sync.lastStatus, isNull);
    sync.dispose();
    await tester.pump(const Duration(minutes: 6));
    expect(tester.takeException(), isNull);
  });

  test(
      'support-directory ownership rejects real competing process and recovers after kill',
      () async {
    final root =
        await Directory.systemTemp.createTemp('nntdrive-session-test-');
    addTearDown(() => root.delete(recursive: true));
    final args = [
      '--packages=.dart_tool/package_config.json',
      'tool/desktop_instance_probe.dart',
      root.path
    ];
    final owner = await Process.start('dart', args);
    addTearDown(() async {
      owner.kill();
      await owner.exitCode;
    });
    final stderr = owner.stderr.transform(utf8.decoder).join();
    final line = await owner.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 30));
    expect(line, 'owned');
    await expectLater(
        DesktopInstance.acquire(root), throwsA(isA<FileSystemException>()));
    final competitor = await Process.run('dart', args);
    expect(competitor.exitCode, 75, reason: competitor.stderr.toString());
    expect(competitor.stdout.toString().trim(), 'busy');
    owner.kill(ProcessSignal.sigkill);
    await owner.exitCode;
    expect(await stderr, isEmpty);
    final recovered = await DesktopInstance.acquire(root);
    expect(await File('${root.path}/desktop-session.lock').exists(), isTrue);
    await recovered.release();
    final again = await DesktopInstance.acquire(root);
    await again.release();
  },
      skip: Platform.isWindows
          ? 'Linux subprocess fixture; Windows installed runner acceptance is separate'
          : false);
}
