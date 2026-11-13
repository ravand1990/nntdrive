import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Records the remote folder a new sync folder is created under.
class FakeFilesApi extends ApiClient {
  FakeFilesApi() : super(baseUrl: 'http://unused');

  final List<({String id, String? parentId, String nameEnc, bool isDir})>
      created = [];
  int? createFailureStatus;

  @override
  Future<void> createFile({
    required String id,
    required String? parentId,
    required String nameEnc,
    required bool isDir,
  }) async {
    if (createFailureStatus != null) {
      throw ApiException(createFailureStatus!, 'error', 'create failed');
    }
    created.add((id: id, parentId: parentId, nameEnc: nameEnc, isDir: isDir));
  }
}

String openSealed(String sealed) => utf8.decode(base64Decode(sealed));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late FakeFilesApi api;
  late List<SyncController> controllers;
  var nativeCalls = 0;
  var sealed = <String>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sync-destination-');
    await Directory('${root.path}/notes').create();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
    api = FakeFilesApi();
    controllers = [];
    nativeCalls = 0;
    sealed = [];
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    await root.delete(recursive: true);
  });

  SyncController controllerWith({String? deviceRootNodeId}) {
    final controller = SyncController(
      server: 'http://unused',
      token: 'private-token',
      handle: 0,
      api: api,
      nameSealer: (nodeId, name) {
        final envelope = base64Encode(utf8.encode('$name|$nodeId'));
        sealed.add(envelope);
        return envelope;
      },
      rootsLoader: () async =>
          AccountRootsResult(const [], deviceRootNodeId: deviceRootNodeId),
      syncRunner: (handle, request, progress) async {
        nativeCalls++;
        return {'uploaded': 0, 'downloaded': 0, 'conflicts': 0, 'errors': []};
      },
    );
    controllers.add(controller);
    return controller;
  }

  test('a folder added on this device lands inside this device space',
      () async {
    final sync = controllerWith(deviceRootNodeId: 'device-root');
    await sync.load();

    expect(await sync.addFolder('${root.path}/notes'), isTrue);

    expect(sync.deviceRootNodeId, 'device-root');
    expect(api.created, hasLength(1));
    final created = api.created.single;
    expect(created.parentId, 'device-root');
    expect(created.isDir, isTrue);
    // The sealed name stays bound to the node ID that was sent.
    expect(openSealed(created.nameEnc), 'notes|${created.id}');
    expect(sync.folders.single.remoteRootId, created.id);
    expect(sync.lastStatus, contains('device space'));
    expect(nativeCalls, 1);
  });

  test('without a device space the folder stays at the account root', () async {
    final sync = controllerWith();
    await sync.load();

    expect(await sync.addFolder('${root.path}/notes'), isTrue);

    expect(sync.deviceRootNodeId, isNull);
    expect(api.created.single.parentId, isNull);
    expect(sync.folders, hasLength(1));
    expect(sync.lastStatus, 'Folder added and synchronized.');
  });

  test('a refused remote create admits neither a folder nor a sync', () async {
    final sync = controllerWith(deviceRootNodeId: 'device-root');
    await sync.load();
    api.createFailureStatus = 409;

    expect(await sync.addFolder('${root.path}/notes'), isFalse);

    expect(sync.folders, isEmpty);
    expect(nativeCalls, 0);
    expect(sync.lastStatus, contains('Could not create the remote folder'));
    expect(sync.lastStatus, isNot(contains('private-token')));
  });
}
