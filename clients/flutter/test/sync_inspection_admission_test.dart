import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/storage_access.dart';
import 'package:nntdrive/sync_controller.dart';

class GatedPermission extends StorageAccess {
  Completer<bool>? gate;
  int calls = 0;
  @override
  Future<bool> permissionRequired(String path) async {
    calls++;
    return gate == null ? false : await gate!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SyncController sync;
  late SyncFolderConfig folder;
  late GatedPermission access;
  var inspections = 0;
  Completer<String>? journalGate;
  Completer<void>? journalEntered;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('inspection-admission-');
    access = GatedPermission();
    inspections = 0;
    journalGate = null;
    journalEntered = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), (call) async {
      journalEntered?.complete();
      return journalGate == null ? root.path : await journalGate!.future;
    });
    sync = SyncController(
        server: 'http://unused', token: 'unused', handle: 0,
        api: ApiClient(baseUrl: 'http://unused'), storageAccess: access,
        inspectRunner: (_, request) async {
          inspections++;
          return {'items': []};
        });
    folder = SyncFolderConfig(id: 'f', name: 'f', localPath: root.path,
        remoteRootId: 'opaque');
    sync.folders.add(folder);
  });
  tearDown(() async {
    sync.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
    await root.delete(recursive: true);
  });

  test('running at controller admission skips permission and native work', () async {
    folder.running = true;
    expect(await sync.inspectFolder(folder), {'sync_running': true});
    expect(access.calls, 0);
    expect(inspections, 0);
    expect(await Directory('${root.path}/sync').exists(), isFalse);
  });

  test('sync starting while permission is suspended skips journal and native',
      () async {
    access.gate = Completer<bool>();
    final pending = sync.inspectFolder(folder);
    folder.running = true;
    access.gate!.complete(false);
    expect(await pending, {'sync_running': true});
    expect(inspections, 0);
    expect(await Directory('${root.path}/sync').exists(), isFalse);
  });

  test('sync starting while journal lookup is suspended skips native', () async {
    journalGate = Completer<String>();
    journalEntered = Completer<void>();
    final pending = sync.inspectFolder(folder);
    await journalEntered!.future;
    folder.running = true;
    journalGate!.complete(root.path);
    expect(await pending, {'sync_running': true});
    expect(inspections, 0);
    expect(await File('${root.path}/sync/f.sqlite').exists(), isFalse);
  });

  test('shutdown during permission check drains without native admission', () async {
    access.gate = Completer<bool>();
    final pending = sync.inspectFolder(folder);
    final drain = sync.stopAndDrain();
    access.gate!.complete(false);
    expect(await pending, isEmpty);
    await drain;
    expect(inspections, 0);
  });
}
