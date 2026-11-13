import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';

/// Only the account-root listing is meaningful for migration detection.
class FakeTopLevelApi extends ApiClient {
  FakeTopLevelApi() : super(baseUrl: 'http://unused');

  List<RemoteFile> topLevel = const [];
  int listCalls = 0;
  ApiException? failure;

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    if (parentId != null) {
      throw StateError('migration detection must only list the account root');
    }
    listCalls++;
    if (failure != null) throw failure!;
    return topLevel;
  }
}

AccountRoot globalRoot() =>
    AccountRoot(rootId: 'g', kind: 'global', nodeId: 'global-node', nameEnc: 'x');

AccountRoot deviceRoot() => AccountRoot(
      rootId: 'd',
      kind: 'device',
      nodeId: 'device-node',
      nameEnc: 'x',
      deviceName: 'Workstation',
    );

RemoteFile folderNode(String id) =>
    RemoteFile(id, null, 'sealed', true, 0, false, 1, null);

SyncController controllerWith(FakeTopLevelApi api) => SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: api,
      syncRunner: (handle, request, progress) async =>
          {'uploaded': 0, 'downloaded': 0, 'conflicts': 0, 'errors': []},
    );

void main() {
  test('a synced folder at the account root is reported for migration',
      () async {
    final api = FakeTopLevelApi()
      ..topLevel = [
        folderNode('global-node'),
        folderNode('device-node'),
        folderNode('legacy-folder'),
        folderNode('some-other-folder'),
      ];
    final sync = controllerWith(api);
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([globalRoot(), deviceRoot()]);
    sync.deviceRootNodeId = 'device-node';
    sync.folders.add(SyncFolderConfig(
        id: 'f1',
        name: 'Notes',
        localPath: '/library/Notes',
        remoteRootId: 'legacy-folder'));

    await sync.refreshLegacyFolders();

    expect(api.listCalls, 1);
    expect(sync.legacySpaceFolders.map((f) => f.id), ['legacy-folder']);
  });

  test('folders already inside a space are never reported', () async {
    final api = FakeTopLevelApi()
      ..topLevel = [folderNode('global-node'), folderNode('device-node')];
    final sync = controllerWith(api);
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([globalRoot(), deviceRoot()]);
    sync.deviceRootNodeId = 'device-node';
    sync.folders.addAll([
      SyncFolderConfig(
          id: 'f1',
          name: 'Global',
          localPath: '/library/Global',
          remoteRootId: 'global-node'),
      SyncFolderConfig(
          id: 'f2',
          name: 'Workstation',
          localPath: '/library/Workstation',
          remoteRootId: 'device-node'),
    ]);

    await sync.refreshLegacyFolders();

    expect(sync.legacySpaceFolders, isEmpty);
  });

  test('no listing happens without spaces or sync folders', () async {
    final api = FakeTopLevelApi();
    final sync = controllerWith(api);
    addTearDown(sync.dispose);
    sync.folders.add(SyncFolderConfig(
        id: 'f1',
        name: 'Notes',
        localPath: '/library/Notes',
        remoteRootId: 'legacy-folder'));

    await sync.refreshLegacyFolders();
    expect(api.listCalls, 0, reason: 'spaces are unknown, so nothing is guessed');

    sync.accountRoots.add(globalRoot());
    sync.folders.clear();
    await sync.refreshLegacyFolders();
    expect(api.listCalls, 0);
    expect(sync.legacySpaceFolders, isEmpty);
  });

  test('a failed listing clears the notice instead of keeping stale rows',
      () async {
    final api = FakeTopLevelApi()
      ..topLevel = [folderNode('global-node'), folderNode('legacy-folder')]
      ..failure = ApiException(0, 'network', 'offline');
    final sync = controllerWith(api);
    addTearDown(sync.dispose);
    sync.accountRoots.add(globalRoot());
    sync.deviceRootNodeId = null;
    sync.legacySpaceFolders = [folderNode('legacy-folder')];

    await sync.refreshLegacyFolders();

    expect(sync.legacySpaceFolders, isEmpty);
    expect(sync.lastStatus, isNull, reason: 'detection is advisory only');
  });
}
