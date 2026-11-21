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
    required Future<Map<String, dynamic>> Function(
            void Function(Map<String, dynamic>) progress)
        run,
  }) {
    return SyncController(
      server: 'http://unused',
      token: 'secret-token',
      handle: 0,
      api: _UnusedApi(),
      rootsLoader: () async =>
          const AccountRootsResult([], deviceRootNodeId: 'device-root'),
      syncRunner: (handle, request, progress) => run(progress),
      onRunFinished: (folder, report) =>
          recordSyncRunActivity(log, folder, report),
    );
  }

  test('one finished sync run records its counts once', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: (_) async => {
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
      run: (_) async => throw StateError('native failure'),
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

  test('a finished run names each completed transfer once', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: (progress) async {
        // A running transfer is not a completed one.
        progress({
          'path': 'notes/today.txt',
          'direction': 'upload',
          'bytes': 6,
          'total': 12,
          'complete': false,
        });
        progress({
          'path': 'notes/today.txt',
          'direction': 'upload',
          'bytes': 12,
          'total': 12,
          'complete': true,
        });
        // A repeated completion must not add a second row.
        progress({
          'path': 'notes/today.txt',
          'direction': 'upload',
          'bytes': 12,
          'total': 12,
          'complete': true,
        });
        // Windows separators still yield the plain file name.
        progress({
          'path': 'photos\\2026\\a.jpg',
          'direction': 'download',
          'bytes': 4096,
          'total': 4096,
          'complete': true,
        });
        return {
          'uploaded': 1,
          'downloaded': 1,
          'conflicts': 0,
          'errors': <Object>[],
        };
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

    expect(log.entries.length, 2);
    final uploaded = log.entries
        .firstWhere((entry) => entry.kind == ActivityKind.uploaded);
    expect(uploaded.subject, 'today.txt');
    expect(uploaded.size, 12);
    expect(uploaded.folder, 'Documents');
    expect(uploaded.folderRootId, 'root-1');
    final downloaded = log.entries
        .firstWhere((entry) => entry.kind == ActivityKind.downloaded);
    expect(downloaded.subject, 'a.jpg');
    expect(downloaded.size, 4096);
    controller.dispose();
  });

  test('unobserved transfers keep the plain count row', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: (progress) async {
        progress({
          'path': 'big.iso',
          'direction': 'download',
          'bytes': 10,
          'total': 100,
          'complete': false,
        });
        return {
          'uploaded': 0,
          'downloaded': 1,
          'conflicts': 0,
          'errors': <Object>[],
        };
      },
    );
    final config = SyncFolderConfig(
      id: 'f',
      name: 'Backups',
      localPath: '${root.path}/backups',
      remoteRootId: 'root-3',
    );
    await Directory('${root.path}/backups').create();
    controller.folders.add(config);

    await controller.syncFolder(config);

    expect(log.entries.length, 1);
    expect(log.entries.single.kind, ActivityKind.downloaded);
    expect(log.entries.single.subject, '1 item');
    expect(log.entries.single.size, isNull);
    controller.dispose();
  });

  test('transfers beyond the named rows become one remainder row', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: (progress) async {
        for (final name in ['a.txt', 'b.txt']) {
          progress({
            'path': name,
            'direction': 'upload',
            'bytes': 1,
            'total': 1,
            'complete': true,
          });
        }
        return {
          'uploaded': 5,
          'downloaded': 0,
          'conflicts': 0,
          'errors': <Object>[],
        };
      },
    );
    final config = SyncFolderConfig(
      id: 'f',
      name: 'Projects',
      localPath: '${root.path}/projects',
      remoteRootId: 'root-4',
    );
    await Directory('${root.path}/projects').create();
    controller.folders.add(config);

    await controller.syncFolder(config);

    final subjects = log.entries.map((entry) => entry.subject).toList();
    expect(subjects, containsAll(<String>['a.txt', 'b.txt', '3 more items']));
    expect(log.entries.length, 3);
    expect(
      log.entries.every((entry) => entry.kind == ActivityKind.uploaded),
      isTrue,
    );
    controller.dispose();
  });

  test('a later run does not reuse the previous run transfers', () async {
    final log = newLog();
    await log.load();
    var emit = true;
    final controller = controllerFor(
      log,
      run: (progress) async {
        if (emit) {
          progress({
            'path': 'one.txt',
            'direction': 'upload',
            'bytes': 1,
            'total': 1,
            'complete': true,
          });
          return {
            'uploaded': 1,
            'downloaded': 0,
            'conflicts': 0,
            'errors': <Object>[],
          };
        }
        return {
          'uploaded': 0,
          'downloaded': 0,
          'conflicts': 0,
          'errors': <Object>[],
        };
      },
    );
    final config = SyncFolderConfig(
      id: 'f',
      name: 'Notes',
      localPath: '${root.path}/notes',
      remoteRootId: 'root-5',
    );
    await Directory('${root.path}/notes').create();
    controller.folders.add(config);

    await controller.syncFolder(config);
    expect(log.entries.length, 1);

    emit = false;
    await controller.syncFolder(config);
    expect(log.entries.length, 1);
    expect(log.entries.single.subject, 'one.txt');
    controller.dispose();
  });

  test('repeated completions collapse and the run stays bounded', () async {
    final log = newLog();
    await log.load();
    final controller = controllerFor(
      log,
      run: (progress) async {
        for (var i = 0; i < 300; i++) {
          progress({
            'path': 'same.txt',
            'direction': 'upload',
            'bytes': 1,
            'total': 1,
            'complete': true,
          });
        }
        for (var i = 0; i < 300; i++) {
          progress({
            'path': 'file-$i.txt',
            'direction': 'upload',
            'bytes': 1,
            'total': 1,
            'complete': true,
          });
        }
        return {
          'uploaded': 301,
          'downloaded': 0,
          'conflicts': 0,
          'errors': <Object>[],
        };
      },
    );
    final config = SyncFolderConfig(
      id: 'f',
      name: 'Bulk',
      localPath: '${root.path}/bulk',
      remoteRootId: 'root-6',
    );
    await Directory('${root.path}/bulk').create();
    controller.folders.add(config);

    await controller.syncFolder(config);

    // One row per distinct path and direction, bounded by the transfer limit.
    expect(
      config.completedTransfers.length,
      SyncController.completedTransferLimit,
    );
    expect(
      config.completedTransfers
          .where((transfer) => transfer.path == 'same.txt')
          .length,
      1,
    );
    // The feed names a prefix and summarises the rest instead of flooding.
    final uploaded = log.entries
        .where((entry) => entry.kind == ActivityKind.uploaded)
        .toList();
    expect(uploaded.length, activityTransferRowLimit + 1);
    expect(uploaded.first.subject, contains('more items'));
    controller.dispose();
  });
}
