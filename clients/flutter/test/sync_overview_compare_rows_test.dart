import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:shared_preferences/shared_preferences.dart';

SyncFolderConfig folder(String id) => SyncFolderConfig(
    id: id, name: id, localPath: '/unused', remoteRootId: id);

Map<String, dynamic> comparedEntry(String path, {bool isDir = false}) =>
    <String, dynamic>{'path': path, 'is_dir': isDir};

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
    root = await Directory.systemTemp.createTemp('sync-compare-rows-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('the compare view replaces scan rows, bounds itself and clears', () async {
    final started = Completer<void>();
    final release = Completer<void>();
    final controller = SyncController(
      server: 'http://unused',
      token: 'private-token',
      handle: 0,
      api: _UnusedApi(),
      rootsLoader: () async =>
          const AccountRootsResult([], deviceRootNodeId: 'device-root'),
      syncRunner: (handle, request, progress) async {
        progress(<String, dynamic>{
          'phase': 'scan',
          'items': [
            {'path': 'local.txt', 'is_dir': false},
          ],
        });
        progress(<String, dynamic>{
          'phase': 'compare',
          'items': [
            {'path': 'remote.txt', 'is_dir': false},
            {'path': 'nested', 'is_dir': true},
          ],
        });
        progress(<String, dynamic>{
          'phase': 'compare',
          'items': [
            for (var i = 0; i < SyncController.activeCompareLimit + 4; i++)
              {'path': 'bulk/$i.txt', 'is_dir': false},
          ],
        });
        started.complete();
        await release.future;
        return {'uploaded': 0, 'downloaded': 0, 'conflicts': 0, 'errors': []};
      },
    );

    await Directory('${root.path}/notes').create();
    final config = SyncFolderConfig(
        id: 'f', name: 'f', localPath: '${root.path}/notes', remoteRootId: 'r');
    controller.folders.add(config);
    final run = controller.syncFolder(config);
    await started.future;

    // The snapshot phase supersedes the scan rows instead of mixing both.
    expect(config.activeScanEntries, isEmpty);
    expect(config.activeScanTotal, 0);
    expect(config.activeCompareStarted, isTrue);
    expect(config.activeCompareTotal, SyncController.activeCompareLimit + 6);
    expect(config.activeCompareEntries.length, SyncController.activeCompareLimit);
    expect(config.activeCompareEntries.first,
        {'path': 'remote.txt', 'is_dir': false});
    expect(config.activeCompareEntries[1], {'path': 'nested', 'is_dir': true});
    // A compare batch is not a transfer and must not masquerade as one.
    expect(config.progress, isNull);

    release.complete();
    await run;
    expect(config.running, isFalse);
    expect(config.activeCompareEntries, isEmpty);
    expect(config.activeCompareTotal, 0);
    expect(config.activeCompareStarted, isFalse);
    controller.dispose();
  });

  test('a comparing folder lists the remote paths already compared', () async {
    final active = folder('active')
      ..running = true
      ..activeCompareStarted = true
      ..activeCompareTotal = 3
      ..activeCompareEntries = [
        comparedEntry('nested/inner.txt'),
        comparedEntry('uploaded.txt'),
        comparedEntry('nested', isDir: true),
      ];

    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async => fail('no inspection'));

    final rows = result.entries;
    expect(rows.map((row) => row.path),
        ['nested', 'nested/inner.txt', 'uploaded.txt']);
    expect(rows.map((row) => row.status),
        everyElement(UnsyncedStatus.pending));
    expect(rows.every((row) => row.retryable), isFalse);
    expect(rows.every((row) => row.lastAttempt == null), isTrue);
    expect(rows.every((row) => row.reason == 'Comparing with the remote copy.'),
        isTrue);
    expect(rows.first.isDirectory, isTrue);
    expect(rows[1].isDirectory, isFalse);
    expect(result.counts, {UnsyncedStatus.pending: 3});
    expect(result.folders.single.total, 3);
    expect(result.notices.single.message, contains('Comparing this folder'));
    expect(result.notices.single.message, contains('plan'));
    expect(result.truncated, isFalse);
  });

  test('an empty remote folder keeps one root row while comparing', () async {
    final active = folder('active')
      ..running = true
      ..activeCompareStarted = true;

    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async => fail('no inspection'));

    final row = result.entries.single;
    expect(row.path, '');
    expect(row.isDirectory, isTrue);
    expect(row.status, UnsyncedStatus.pending);
    expect(row.reason, 'Comparing this folder with the remote copy.');
    expect(result.notices.single.message, contains('Comparing this folder'));
  });

  test('the reconciliation plan replaces compared rows once it arrives',
      () async {
    final active = folder('active')
      ..running = true
      ..activeCompareStarted = true
      ..activeCompareTotal = 2
      ..activeCompareEntries = [comparedEntry('remote.txt'), comparedEntry('gone.txt')]
      ..activePlanTotal = 1
      ..activePlan = [planItem('download', 'remote.txt', size: 7)];

    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async => fail('no inspection'));

    expect(result.entries.map((row) => row.path), ['remote.txt']);
    expect(result.entries.single.reason, 'Waiting to download this file.');
    expect(result.notices, isEmpty);
  });

  test('a capped compare view reports how many paths are shown', () async {
    final active = folder('active')
      ..running = true
      ..activeCompareStarted = true
      ..activeCompareTotal = 4096
      ..activeCompareEntries = [
        comparedEntry('a.txt'),
        comparedEntry('b.txt'),
        comparedEntry('c.txt'),
      ];

    final result = await buildUnsyncedOverview(
        folders: [active],
        inspect: (_) async => fail('no inspection'),
        maxEntries: 2);

    expect(result.entries.map((row) => row.path), ['a.txt', 'b.txt']);
    expect(result.truncated, isTrue);
    expect(result.notices.single.message, contains('Showing 2 of 4096'));
    expect(result.notices.single.message, contains('plan'));
  });
}
