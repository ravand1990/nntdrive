import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/storage_access.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // This file has no widget tests. Keep the loopback server real even though
  // controller journal paths/preferences require a mock plugin messenger.
  HttpOverrides.global = null;
  late Directory state;
  late HttpServer server;
  late int handle;
  late int requests;
  final bridge = NativeBridge.instance;

  setUp(() async {
    state = await Directory.systemTemp.createTemp('inspection-native-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => state.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = 0;
    server.listen((request) async {
      requests++;
      request.response.statusCode = 503;
      request.response.write('private remote diagnostic');
      await request.response.close();
    });
    const password = 'inspection fixture password';
    final account = bridge.generateAccount(password);
    handle = bridge.unlock(jsonEncode(account['keyfile']), password)['handle']
        as int;
  });

  tearDown(() async {
    await bridge.drainSession(handle);
    bridge.lock(handle);
    await server.close(force: true);
    await state.delete(recursive: true);
  });

  Map<String, dynamic> request(String root) => {
        'baseUrl': 'http://127.0.0.1:${server.port}',
        'token': 'fixture-token',
        'remoteRootId': '00000000-0000-0000-0000-000000000001',
        'localPath': root,
        'journalPath': '${state.path}/journal.sqlite',
        'deviceName': 'fixture',
        'excluded': <String>[],
      };

  test(
      'native invalid roots become counted Blocked rows without HTTP or journal',
      () async {
    final file =
        await File('${state.path}/private-file').writeAsString('preserve');
    for (final fixture in [
      ('${state.path}/private-missing', 'not_found'),
      (file.path, 'not_a_directory'),
    ]) {
      final result = await bridge.syncInspectAsync(handle, request(fixture.$1));
      expect(result['filesystem_blocked'], fixture.$2);
      expect(result['items'], isEmpty);
      expect(result.toString(), isNot(contains('private-')));
      final overview = await buildUnsyncedOverview(
        folders: [
          SyncFolderConfig(
              id: 'root',
              name: 'Documents',
              localPath: fixture.$1,
              remoteRootId: '00000000-0000-0000-0000-000000000001')
        ],
        inspect: (_) async => result,
      );
      expect(overview.filtered(status: UnsyncedStatus.blocked).single.path, '');
      expect(overview.folders.single.total, 1);
      expect(overview.counts[UnsyncedStatus.blocked], 1);
      expect(overview.notices, isEmpty);
    }
    expect(requests, 0);
    expect(await File('${state.path}/journal.sqlite').exists(), isFalse);
    expect(await file.readAsString(), 'preserve');
    await expectLater(bridge.syncInspectAsync(0, request(file.path)),
        throwsA(isA<NativeException>()));
    expect(requests, 0);
  });

  test(
      'native unreadable root, directory and file return safe blocks before HTTP',
      () async {
    final root = await Directory('${state.path}/root').create();
    final nested = await Directory('${root.path}/nested').create();
    final file =
        await File('${nested.path}/private-file').writeAsString('preserve');
    for (final denied in [root.path, nested.path, file.path]) {
      final chmod = await Process.run('chmod', ['000', denied]);
      expect(chmod.exitCode, 0);
      Map<String, dynamic> result;
      try {
        result = await bridge.syncInspectAsync(handle, request(root.path));
      } finally {
        expect((await Process.run('chmod', ['700', denied])).exitCode, 0);
      }
      expect(result['filesystem_blocked'], 'permission_denied');
      expect(result['items'], isEmpty);
      expect(result['skipped'], isEmpty);
      expect(result.toString(), isNot(contains('private-file')));
    }
    expect(requests, 0);
    expect(await File('${state.path}/journal.sqlite').exists(), isFalse);
    expect(await file.readAsString(), 'preserve');
  }, skip: !Platform.isLinux);

  for (final kind in ['missing', 'file', 'unreadable']) {
    test(
        'controller $kind root becomes counted Blocked through native overview',
        () async {
      final rootPath = '${state.path}/private-root';
      if (kind == 'file') await File(rootPath).writeAsString('preserve');
      if (kind == 'unreadable') {
        await Directory(rootPath).create();
        expect((await Process.run('chmod', ['000', rootPath])).exitCode, 0);
        addTearDown(() async {
          expect((await Process.run('chmod', ['700', rootPath])).exitCode, 0);
        });
      }
      final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
      final sync = SyncController(
          server: api.baseUrl,
          token: 'fixture-token',
          handle: handle,
          api: api);
      addTearDown(sync.dispose);
      final folder = SyncFolderConfig(
          id: 'root',
          name: 'Documents',
          localPath: rootPath,
          remoteRootId: request(rootPath)['remoteRootId'] as String,
          lastSync: '2026-01-01T00:00:00Z',
          lastReport: {'uploaded': 7, 'errors': []});
      sync.folders.add(folder);
      final previousReport = folder.lastReport;

      // Reproduce the admission that previously swallowed the typed native
      // result; the real controller and default native runner must now reach it.
      await expectLater(const StorageAccess().check(rootPath),
          throwsA(isA<StorageAccessException>()));
      final overview = await buildUnsyncedOverview(
          folders: sync.folders, inspect: sync.inspectFolder);
      expect(overview.notices, isEmpty);
      expect(overview.entries, hasLength(1));
      expect(overview.filtered(status: UnsyncedStatus.blocked).single.path, '');
      expect(overview.entries.single.isDirectory, isTrue);
      expect(overview.entries.single.reason, isNot(contains('private-root')));
      expect(overview.folders.single.total, 1);
      expect(overview.counts[UnsyncedStatus.blocked], 1);
      expect(folder.lastReport, same(previousReport));
      expect(folder.lastError, isNull);
      expect(folder.storageAccessRequired, isFalse);

      // Ordinary sync still uses the full listing preflight and fails closed.
      expect(await sync.syncFolder(folder), isNull);
      expect(folder.lastError, contains('Cannot read'));
      expect(folder.lastReport, same(previousReport));
      expect(folder.lastSync, '2026-01-01T00:00:00Z');
      expect(requests, 0);
      expect(await File('${state.path}/sync/root.sqlite').exists(), isFalse);
      if (kind == 'file') {
        expect(await File(rootPath).readAsString(), 'preserve');
      }
    }, skip: kind == 'unreadable' && !Platform.isLinux);
  }

  test('locked controller inspection remains an error, not a filesystem block',
      () async {
    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    final sync = SyncController(
        server: api.baseUrl, token: 'fixture-token', handle: 0, api: api);
    addTearDown(sync.dispose);
    final folder = SyncFolderConfig(
        id: 'root',
        name: 'Documents',
        localPath: '${state.path}/missing',
        remoteRootId: request(state.path)['remoteRootId'] as String);
    sync.folders.add(folder);
    await expectLater(
        sync.inspectFolder(folder), throwsA(isA<NativeException>()));
    final overview = await buildUnsyncedOverview(
        folders: sync.folders, inspect: sync.inspectFolder);
    expect(overview.entries, isEmpty);
    expect(overview.notices.single.message, contains('could not be compared'));
    expect(requests, 0);
    expect(await File('${state.path}/sync/root.sqlite').exists(), isFalse);
  });

  test(
      'native corrupt journal and remote failure remain generic notices, not blocks',
      () async {
    final root = await Directory('${state.path}/root').create();
    final journal =
        await File('${state.path}/journal.sqlite').writeAsString('not sqlite');
    for (final corruptJournal in [true, false]) {
      if (!corruptJournal) await journal.delete();
      final overview = await buildUnsyncedOverview(
        folders: [
          SyncFolderConfig(
              id: 'root',
              name: 'Documents',
              localPath: root.path,
              remoteRootId: '00000000-0000-0000-0000-000000000001')
        ],
        inspect: (_) => bridge.syncInspectAsync(handle, request(root.path)),
      );
      expect(overview.entries, isEmpty);
      expect(
          overview.notices.single.message, contains('could not be compared'));
      expect(overview.notices.single.message, isNot(contains('private')));
      expect(requests, corruptJournal ? 0 : 1);
    }
    expect(await journal.exists(), isFalse);
  });
}
