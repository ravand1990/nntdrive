import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/device_name.dart';
import 'package:nntdrive/device_onboarding.dart';
import 'package:nntdrive/file_rename.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Plain tests only: widget bindings replace real HttpClient transport.
void main() {
  for (final outcome in ['retry', 'conflict', 'collision', 'http500', 'disconnect', 'unverified']) {
    test('onboarding fresh guarded HTTP snapshot: $outcome', () async {
      SharedPreferences.setMockInitialValues({});
      final bridge = NativeBridge.instance;
      const password = 'recovery fixture password';
      final keys = bridge.generateAccount(password);
      final handle = bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
      const target = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const other = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const global = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final original = bridge.sealName(handle, target, 'Old device');
      var sealed = original;
      var otherSealed = bridge.sealName(handle, other, 'Café laptop');
      final globalSealed = bridge.sealName(handle, global, 'Global');
      var posts = 0;
      var bootstraps = 0;
      var rootReads = 0;
      var fileReads = 0;
      final writes = <Map<String, dynamic>>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/me')) {
          request.response.write(jsonEncode({'account_id': 'account', 'devices': [
            {'id': 'device', 'name': 'private ignored', 'platform': 'linux', 'current': true},
          ]}));
        } else if (request.uri.path.endsWith('/roots')) {
          if (request.method != 'GET') bootstraps++;
          rootReads++;
          // Deliberately stale roots metadata after the acknowledged rename.
          request.response.write(jsonEncode({'roots': [
            {'root_id': 'global', 'kind': 'global', 'node_id': global, 'name_enc': globalSealed},
            {'root_id': 'own', 'kind': 'device', 'device_id': 'device', 'node_id': target, 'name_enc': original},
            {'root_id': 'other', 'kind': 'device', 'device_id': 'other-device', 'node_id': other, 'name_enc': otherSealed},
          ]}));
        } else if (request.uri.path.endsWith('/files')) {
          fileReads++;
          request.response.write(jsonEncode({'files': [
            {'id': target, 'name_enc': sealed, 'is_dir': true, 'revision': fileReads},
            {'id': other, 'name_enc': otherSealed, 'is_dir': true},
            {'id': global, 'name_enc': globalSealed, 'is_dir': true},
          ]}));
        } else if (request.uri.path.endsWith('/files/$target/rename')) {
          posts++;
          final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;
          writes.add(body);
          expect(body['siblings'], [
            {'id': target, 'name_enc': sealed},
            {'id': other, 'name_enc': otherSealed},
            {'id': global, 'name_enc': globalSealed},
          ]);
          if (outcome == 'disconnect') {
            final socket = await request.response.detachSocket(writeHeaders: false);
            socket.destroy();
            return;
          }
          if (outcome == 'http500') {
            request.response.statusCode = 500;
          } else if (outcome == 'conflict' || posts == 1 &&
              (outcome == 'retry' || outcome == 'collision')) {
            // The second request must use this new authenticated envelope.
            otherSealed = bridge.sealName(handle, other,
                outcome == 'collision' ? 'CAFE\u0301 LAPTOP (2)' : 'Changed sibling');
            request.response.statusCode = 409;
          } else if (outcome != 'unverified') {
            sealed = body['name_enc'] as String;
          }
          request.response.write('{}');
        } else {
          fail('Unexpected recovery endpoint');
        }
        await request.response.close();
      });
      final address = 'http://127.0.0.1:${server.port}';
      final naming = DeviceNaming(api: ApiClient(baseUrl: address, token: 'fixture'),
          handle: handle, server: address, accountId: 'account');
      try {
        final root = await naming.currentRoot();
        final spaces = await naming.existingSpaces();
        expect(spaces.map((space) => space.name), contains('Café laptop'));
        final suggested = naming.uniqueSuggestion('CAFE\u0301 LAPTOP', spaces, target);
        expect(suggested, 'CAFE\u0301 LAPTOP (2)');
        // Suggestions retain spelling while honoring code-point AND byte limits.
        for (final long in ['x' * 64, '😀' * 63]) {
          final candidate = naming.uniqueSuggestion(long,
              [DeviceSpaceName(other, long)], target);
          expect(deviceNameValidationError(candidate), isNull);
          expect(candidate, endsWith(' (2)'));
        }
        final readsBefore = rootReads;
        final result = naming.confirm(root, suggested);
        if (outcome == 'retry') {
          await result;
          expect(posts, 2);
          expect(rootReads - readsBefore, 2);
          expect(bridge.openName(handle, target, sealed), suggested);
          expect((await SharedPreferences.getInstance()).getBool(naming.key(root)), true);
        } else {
          await expectLater(result, throwsA(isA<Exception>()));
          expect(posts, outcome == 'conflict' ? 2 : 1);
          expect((await SharedPreferences.getInstance()).getBool(naming.key(root)), isNull);
        }
        await naming.currentRoot();
        await naming.currentRoot();
        expect(bootstraps, 0);
        expect(jsonEncode(writes), isNot(contains('LAPTOP')));
        expect(jsonEncode(writes), isNot(contains('Café')));
      } finally {
        bridge.lock(handle);
        await server.close(force: true);
        await subscription.cancel();
      }
    });
  }

  test('device naming uses real encrypted guarded HTTP rename, exact identity and drain', () async {
    SharedPreferences.setMockInitialValues({});
    final bridge = NativeBridge.instance;
    const password = 'private naming fixture password';
    final keys = bridge.generateAccount(password);
    final handle =
        bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
    const rootId = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const globalId = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const otherId = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    var sealed = bridge.sealName(handle, rootId, 'Legacy hostname');
    final globalSealed = bridge.sealName(handle, globalId, 'Global');
    final otherSealed = bridge.sealName(handle, otherId, 'Café laptop');
    var requests = 0;
    final writes = <Map<String, dynamic>>[];
    final renameArrived = Completer<void>();
    final releaseRename = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      expect(request.headers.value('authorization'), 'Bearer fixture');
      final path = request.uri.path;
      if (path.endsWith('/me')) {
        request.response.write(
          jsonEncode({
            'account_id': 'account',
            'devices': [
              {
                'id': 'device',
                'name': 'DO NOT USE PLAINTEXT',
                'platform': 'linux',
                'current': true,
              },
            ],
          }),
        );
      } else if (path.endsWith('/roots')) {
        expect(request.method, 'GET');
        request.response.write(
          jsonEncode({
            'roots': [
              {
                'root_id': 'global-record',
                'kind': 'global',
                'node_id': globalId,
                'name_enc': globalSealed,
              },
              {
                'root_id': 'device-record',
                'kind': 'device',
                'node_id': rootId,
                'device_id': 'device',
                'name_enc': sealed,
                'device_name': 'DO NOT USE PLAINTEXT',
              },
            ],
          }),
        );
      } else if (path.endsWith('/files')) {
        expect(request.method, 'GET');
        request.response.write(
          jsonEncode({
            'files': [
              {'id': rootId, 'name_enc': sealed, 'is_dir': true, 'revision': 7},
              {'id': globalId, 'name_enc': globalSealed, 'is_dir': true},
              {'id': otherId, 'name_enc': otherSealed, 'is_dir': true},
            ],
          }),
        );
      } else if (path.endsWith('/files/$rootId/rename')) {
        expect(request.method, 'POST');
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        writes.add(body);
        renameArrived.complete();
        await releaseRename.future;
        sealed = body['name_enc'] as String;
        request.response.write('{}');
      } else {
        fail('Unexpected endpoint');
      }
      await request.response.close();
    });
    final address = 'http://127.0.0.1:${server.port}';
    final naming = DeviceNaming(
      api: ApiClient(baseUrl: address, token: 'fixture'),
      handle: handle,
      server: address,
      accountId: 'account',
    );
    try {
      final root = await naming.currentRoot();
      expect(root.nodeId, rootId);
      expect(root.deviceName, 'Legacy hostname');
      final before = requests;
      for (final invalid in [
        'NUL',
        'x' * 65,
        'bad\u202e',
        String.fromCharCode(0xd800),
      ]) {
        await expectLater(
          naming.confirm(root, invalid),
          throwsA(isA<RenameFailure>()),
        );
      }
      expect(requests, before);
      await expectLater(
        naming.confirm(root, 'CAFE\u0301 LAPTOP'),
        throwsA(isA<RenameFailure>()),
      );
      expect(writes, isEmpty);
      final operations = SessionOperations();
      final confirmation = operations.run(
        handle,
        () => naming.confirm(root, 'Family laptop'),
      );
      await renameArrived.future;
      var drained = false;
      final drain = operations.drain(handle).then((_) {
        drained = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(drained, false);
      releaseRename.complete();
      await confirmation;
      await drain;
      expect(drained, true);
      expect(writes, hasLength(1));
      expect(writes.single.keys, ['name_enc', 'parent_id', 'siblings']);
      expect(writes.single['parent_id'], isNull);
      expect(jsonEncode(writes), isNot(contains('Family laptop')));
      expect(bridge.openName(handle, rootId, sealed), 'Family laptop');
      expect(
        () => bridge.openName(handle, otherId, sealed),
        throwsA(isA<NativeException>()),
      );
      final updated = await naming.currentRoot();
      expect(updated.rootId, root.rootId);
      expect(updated.nodeId, root.nodeId);
      expect(updated.deviceName, 'Family laptop');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(naming.key(root)), true);
      expect(prefs.getKeys().map((key) => prefs.get(key)).toList(), [true]);
      expect(naming.key(updated), naming.key(root));
      await expectLater(
        operations.run(handle, () => naming.confirm(root, 'late')),
        throwsStateError,
      );
    } finally {
      if (!releaseRename.isCompleted) releaseRename.complete();
      bridge.lock(handle);
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
