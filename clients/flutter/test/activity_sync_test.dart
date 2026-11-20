import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/activity_log.dart';
import 'package:nntdrive/activity_sync.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryActivityStore implements ActivityStore {
  ActivitySnapshot snapshot = const ActivitySnapshot();
  Duration? retention;

  @override
  Future<ActivitySnapshot> load() async => snapshot;

  @override
  Future<void> save(ActivitySnapshot value) async {
    snapshot = value;
  }

  @override
  Future<Duration?> loadRetention() async => retention;

  @override
  Future<void> saveRetention(Duration value) async {
    retention = value;
  }
}

class _UnusedApi extends ApiClient {
  _UnusedApi() : super(baseUrl: 'http://unused');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('activity-sync-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  ActivityLog newLog() =>
      ActivityLog(store: MemoryActivityStore(), accountId: 'account-1');

  SyncController controllerFor(
    ActivityLog log, {
    required Future<Map<String, dynamic>> Function() run,
  }) {
    return SyncController(
      server: 'http://unused',
      token: 'secret-token',
      handle: 0,
      api: _UnusedApi(),
      rootsLoader: () async =>
          const AccountRootsResult([], deviceRootNodeId: 'device-root'),
      syncRunner: (handle, request, progress) => run(),
      onRunFinished: (folder, report) =>
          recordSyncRunActivity(log, folder, report),
    );
  }

  test('one finished sync run records its counts once', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: () async => {
        'uploaded': 2,
        'downloaded': 0,
        'conflicts': 0,
        'errors': [],
      },
    );
    final config = SyncFolderConfig(
      id: 'f',
      name: 'Documents',
      localPath: '${root.path}/notes',
      remoteRootId: 'root-1',
    );
    await Directory('${root.path}/notes').create();
    controller.folders.add(config);

    await controller.syncFolder(config);

    expect(log.entries.length, 1);
    expect(log.entries.single.kind, ActivityKind.uploaded);
    expect(log.entries.single.subject, '2 items');
    expect(log.entries.single.folder, 'Documents');
    expect(log.entries.single.folderRootId, 'root-1');
    controller.dispose();
  });

  test('a sync that fails before a report records one failure row', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: () async => throw StateError('native failure'),
    );
    final config = SyncFolderConfig(
      id: 'f',
      name: 'Photos',
      localPath: '${root.path}/photos',
      remoteRootId: 'root-2',
    );
    await Directory('${root.path}/photos').create();
    controller.folders.add(config);

    await controller.syncFolder(config);

    expect(log.entries.length, 1);
    expect(log.entries.single.kind, ActivityKind.failed);
    expect(log.entries.single.folderRootId, 'root-2');
    expect(
      log.entries.single.reason,
      'Sync failed. Check storage access and server connectivity, then retry.',
    );
    expect(log.notificationCount, 1);
    controller.dispose();
  });
}
