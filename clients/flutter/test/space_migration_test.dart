import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/space_migration.dart';

AccountRoot global(String nodeId) =>
    AccountRoot(rootId: 'g', kind: 'global', nodeId: nodeId, nameEnc: 'x');

AccountRoot device(String nodeId, {String name = 'Workstation'}) => AccountRoot(
      rootId: 'd-$nodeId',
      kind: 'device',
      nodeId: nodeId,
      nameEnc: 'x',
      deviceName: name,
    );

RemoteFile dir(String id, {String? parentId}) =>
    RemoteFile(id, parentId, 'sealed', true, 0, false, 1, null);

RemoteFile file(String id, {String? parentId}) =>
    RemoteFile(id, parentId, 'sealed', false, 10, false, 1, 'v1');

void main() {
  group('foldersOutsideSpaces', () {
    test('reports a synced folder that sits at the account root', () {
      final found = foldersOutsideSpaces(
        accountTopLevel: [
          dir('global-node'),
          dir('device-node'),
          dir('legacy-folder'),
          dir('unrelated-folder'),
        ],
        roots: [global('global-node'), device('device-node')],
        syncRootIds: ['legacy-folder', 'sync-root-not-listed'],
      );
      expect(found.map((f) => f.id), ['legacy-folder']);
    });

    test('never reports a fixed root even when it is also a sync root', () {
      final found = foldersOutsideSpaces(
        accountTopLevel: [dir('global-node'), dir('device-node')],
        roots: [global('global-node'), device('device-node')],
        syncRootIds: ['global-node', 'device-node'],
      );
      expect(found, isEmpty);
    });

    test('a folder inside a space is not a top-level child', () {
      // Only account-root children are passed in; a sync folder created inside
      // the device space never appears there, so it is not a candidate.
      final found = foldersOutsideSpaces(
        accountTopLevel: [dir('global-node'), dir('device-node')],
        roots: [global('global-node'), device('device-node')],
        syncRootIds: ['device-space-child'],
      );
      expect(found, isEmpty);
    });

    test('ignores files, duplicates and unknown spaces', () {
      expect(
        foldersOutsideSpaces(
          accountTopLevel: [file('legacy-file')],
          roots: [global('global-node')],
          syncRootIds: ['legacy-file'],
        ),
        isEmpty,
      );
      expect(
        foldersOutsideSpaces(
          accountTopLevel: [dir('legacy'), dir('legacy')],
          roots: [global('global-node')],
          syncRootIds: ['legacy'],
        ).map((f) => f.id),
        ['legacy'],
      );
      expect(
        foldersOutsideSpaces(
          accountTopLevel: [dir('legacy')],
          roots: const [],
          syncRootIds: ['legacy'],
        ),
        isEmpty,
        reason: 'unknown spaces are never guessed',
      );
    });
  });

  test('a destination is only ever this device space', () {
    final roots = [global('g'), device('d1', name: 'Laptop'), device('d2')];
    expect(thisDeviceSpace(roots, null), isNull);
    expect(thisDeviceSpace(roots, 'missing'), isNull);
    expect(thisDeviceSpace(roots, 'g'), isNull,
        reason: 'Global is never used as a migration destination');
    expect(thisDeviceSpace(roots, 'd2')?.nodeId, 'd2');
  });

  // Real native encryption plus a loopback server: the guarded move itself is
  // exercised rather than reimplemented.
  group('moveFolderIntoDeviceSpace', () {
    late NativeBridge bridge;
    late int handle;
    late String sealedLegacy;
    late String sealedSibling;
    const legacyId = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const siblingId = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const deviceNode = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';

    setUp(() {
      bridge = NativeBridge.instance;
      final keys = bridge.generateAccount('migration test password');
      handle = bridge
          .unlock(jsonEncode(keys['keyfile']), 'migration test password')['handle']
          as int;
      sealedLegacy = bridge.sealName(handle, legacyId, 'Notes');
      sealedSibling = bridge.sealName(handle, siblingId, 'NOTES');
    });

    RemoteFile legacyFolder() =>
        RemoteFile(legacyId, null, sealedLegacy, true, 0, false, 3, null);

    Future<({String message, List<Map<String, dynamic>> writes, List<String> gets})>
        runMove({
      List<Map<String, dynamic>> siblings = const [],
      int moveStatus = 200,
    }) async {
      final writes = <Map<String, dynamic>>[];
      final gets = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'GET') {
          gets.add(request.uri.queryParameters['parent_id'] ?? 'root');
          request.response.write(jsonEncode({'files': siblings}));
        } else {
          expect(request.uri.path, '/api/v1/files/$legacyId/move-checked');
          writes.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          request.response.statusCode = moveStatus;
          request.response.write('{}');
        }
        await request.response.close();
      });
      final api = ApiClient(
          baseUrl: 'http://127.0.0.1:${server.port}', token: 'private-token');
      try {
        final message = await moveFolderIntoDeviceSpace(
          api: api,
          handle: handle,
          folder: legacyFolder(),
          roots: [global('g'), device(deviceNode)],
          deviceRootNodeId: deviceNode,
        );
        return (message: message, writes: writes, gets: gets);
      } finally {
        await subscription.cancel();
        await server.close();
      }
    }

    test('moves the folder into this device space with ciphertext only',
        () async {
      final result = await runMove();
      expect(result.message, contains('Moved into Workstation'));
      expect(result.gets, [deviceNode]);
      expect(result.writes, hasLength(1));
      expect(result.writes.single['parent_id'], deviceNode);
      expect(result.writes.single['source_parent_id'], isNull);
      expect(result.writes.single['source_name_enc'], sealedLegacy);
      expect(jsonEncode(result.writes), isNot(contains('Notes')));
    });

    test('a destination name collision stops without moving or overwriting',
        () async {
      final result = await runMove(siblings: [
        {'id': siblingId, 'name_enc': sealedSibling, 'is_dir': true},
      ]);
      expect(result.message, contains('already exists'));
      expect(result.writes, isEmpty);
    });

    test('a changed source or destination is reported, not retried', () async {
      final result = await runMove(moveStatus: 409);
      expect(result.message, contains('changed'));
      expect(result.writes, hasLength(1));
    });

    test('a server that cannot be reached changes nothing', () async {
      final api = ApiClient(baseUrl: 'http://127.0.0.1:9');
      final message = await moveFolderIntoDeviceSpace(
        api: api,
        handle: handle,
        folder: legacyFolder(),
        roots: [global('g'), device(deviceNode)],
        deviceRootNodeId: deviceNode,
      );
      expect(message, contains('Could not reach the server'));
    });

    test('without a device space nothing is listed or moved', () async {
      var requests = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'files': []}));
        await request.response.close();
      });
      final api =
          ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 't');
      try {
        final message = await moveFolderIntoDeviceSpace(
          api: api,
          handle: handle,
          folder: legacyFolder(),
          roots: [global('g'), device('another-device')],
          deviceRootNodeId: null,
        );
        expect(message, contains('no device space'));
        expect(requests, 0, reason: 'no request is needed without a destination');
      } finally {
        await subscription.cancel();
        await server.close();
      }
    });
  });
}
