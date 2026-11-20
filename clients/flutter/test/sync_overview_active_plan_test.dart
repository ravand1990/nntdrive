import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:nntdrive/sync_overview_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

SyncFolderConfig folder(String id) => SyncFolderConfig(
    id: id, name: id, localPath: '/unused', remoteRootId: id);

Map<String, dynamic> planItem(String kind, String path,
        {String? pathTo, int? size, bool isDir = false}) =>
    <String, dynamic>{
      'kind': kind,
      'path': path,
      'path_to': pathTo,
      'size': size,
      'is_dir': isDir,
    };

class _UnusedApi extends ApiClient {
  _UnusedApi() : super(baseUrl: 'http://unused');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync-active-plan-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('controller keeps every queued plan path and clears it per run',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final controller = SyncController(
      server: 'http://unused',
      token: 'private-token',
      handle: 0,
      api: _UnusedApi(),
      rootsLoader: () async => const AccountRootsResult([],
          deviceRootNodeId: 'device-root'),
      syncRunner: (handle, request, progress) async {
        progress(<String, dynamic>{
          'phase': 'plan',
          'total': 3,
          'items': [
            {'kind': 'upload', 'path': 'a.txt', 'size': 3, 'is_dir': false},
            {
              'kind': 'download',
              'path': 'nested/b.txt',
              'size': 4,
              'is_dir': false,
            },
            {'kind': 'create_remote_dir', 'path': 'sub', 'is_dir': true},
          ],
        });
        progress(<String, dynamic>{
          'path': 'nested/b.txt',
          'direction': 'download',
          'bytes': 0,
          'total': 4,
          'complete': false,
        });
        started.complete();
        await release.future;
        progress(<String, dynamic>{
          'path': 'nested/b.txt',
          'direction': 'download',
          'bytes': 4,
          'total': 4,
          'complete': true,
        });
        return {'uploaded': 1, 'downloaded': 1, 'conflicts': 0, 'errors': []};
      },
    );

    await Directory('${root.path}/notes').create();
    final config = SyncFolderConfig(
        id: 'f', name: 'f', localPath: '${root.path}/notes', remoteRootId: 'r');
    controller.folders.add(config);
    final run = controller.syncFolder(config);
    await started.future;

    expect(config.activePlanKnown, isTrue);
    expect(config.activePlanTotal, 3);
    expect(config.activePlan.map((item) => item['path']),
        ['a.txt', 'nested/b.txt', 'sub']);
    expect(config.activeTransferPaths, {'nested/b.txt'});

    release.complete();
    await run;
    expect(config.running, isFalse);
    expect(config.activePlan, isEmpty);
    expect(config.activePlanTotal, isNull);
    expect(config.activeTransferPaths, isEmpty);
    controller.dispose();
  });

  test('a running sync lists every planned path instead of one summary row',
      () async {
    final active = folder('active')
      ..running = true
      ..activePlanTotal = 3
      ..activePlan = [
        planItem('upload', 'a.txt', size: 3),
        planItem('download', 'nested/b.txt', size: 4),
        planItem('conflict', 'notes.md', pathTo: 'notes (conflict 1).md'),
      ]
      ..activeTransferPaths = {'nested/b.txt'};

    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async => fail('no inspection'));

    final rows = result.entries;
    expect(rows.map((row) => row.path), ['a.txt', 'nested/b.txt', 'notes.md']);
    expect(rows.map((row) => row.status), [
      UnsyncedStatus.pending,
      UnsyncedStatus.pending,
      UnsyncedStatus.conflict,
    ]);
    expect(rows[0].reason, 'Waiting to upload this file.');
    expect(rows[1].reason, 'Downloading this file.');
    expect(rows[2].reason, contains('keep both'));
    expect(rows[2].pathTo, 'notes (conflict 1).md');
    expect(rows.every((row) => row.retryable), isFalse);
    expect(result.counts,
        {UnsyncedStatus.pending: 2, UnsyncedStatus.conflict: 1});
    expect(result.folders.single.total, 3);
    expect(result.notices, isEmpty);
    expect(result.truncated, isFalse);
  });

  test('a capped plan reports how many queued items are shown', () async {
    final active = folder('active')
      ..running = true
      ..activePlanTotal = 500
      ..activePlan = [
        planItem('upload', 'a.txt'),
        planItem('upload', 'b.txt'),
      ];

    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async => {});
    expect(result.entries, hasLength(2));
    expect(result.notices.single.message, contains('Showing 2 of 500'));
    expect(result.truncated, isTrue);
  });

  test('the shared row budget also bounds plan rows', () async {
    final active = folder('active')
      ..running = true
      ..activePlanTotal = 3
      ..activePlan = [
        planItem('upload', 'a.txt'),
        planItem('upload', 'b.txt'),
        planItem('upload', 'c.txt'),
      ];

    final result = await buildUnsyncedOverview(
        folders: [active], maxEntries: 2, inspect: (_) async => {});
    expect(result.entries, hasLength(2));
    expect(result.truncated, isTrue);
    expect(result.notices.single.message, contains('Showing 2 of 3'));
  });

  test('plan paths never leak absolute local locations', () async {
    final active = folder('active')
      ..running = true
      ..activePlanTotal = 1
      ..activePlan = [planItem('upload', 'nested/private.txt')];

    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async => {});
    expect(result.entries.single.path, 'nested/private.txt');
    expect(result.entries.single.path.startsWith('/'), isFalse);
  });

  testWidgets('queued plan rows render their phase without a sync action',
      (tester) async {
    final active = folder('active')
      ..running = true
      ..activePlanTotal = 2
      ..activePlan = [
        planItem('upload', 'nested/queued.txt'),
        planItem('download', 'nested/fetching.txt'),
      ]
      ..activeTransferPaths = {'nested/fetching.txt'};

    final result = (await tester.runAsync(() => buildUnsyncedOverview(
        folders: [active], inspect: (_) async => {})))!;
    await tester.pumpWidget(MaterialApp(
      home: SyncOverviewPage(
        load: (_) async => result,
        onSyncFolder: (_) async => fail('A running sync must not be retried'),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Waiting to upload this file.'), findsOneWidget);
    expect(find.text('Downloading this file.'), findsOneWidget);
    expect(find.text('Sync is running.'), findsNothing);
    expect(find.byTooltip('Sync active now'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
