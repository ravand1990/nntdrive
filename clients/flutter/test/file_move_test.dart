import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/file_move.dart';
import 'package:nntdrive/file_rename.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('move preserves ciphertext and guards canonical collisions and races', () async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('move test password');
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), 'move test password')['handle'] as int;
    const id = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const sibling = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const destination = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final sealed = bridge.sealName(handle, id, 'Cafe\u0301.txt');
    final file = RemoteFile(id, null, sealed, false, 42, true, 7, 'version');
    var rows = <Map<String, dynamic>>[];
    final writes = <Map<String, dynamic>>[];
    var status = 200;
    var reads = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        reads++;
        expect(request.uri.queryParameters['parent_id'], destination);
        request.response.write(jsonEncode({'files': rows}));
      } else {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/v1/files/$id/move-checked');
        writes.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        request.response.statusCode = status;
        request.response.write('{}');
      }
      await request.response.close();
    });
    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'test');
    Future<void> move() => moveRemoteEntry(api: api, handle: handle, file: file, parentId: destination);
    try {
      rows = [{'id': sibling, 'name_enc': bridge.sealName(handle, sibling, 'CAFÉ.TXT')}];
      await expectLater(move(), throwsA(isA<RenameFailure>()));
      expect(writes, isEmpty);
      rows[0]['name_enc'] = 'invalid';
      await expectLater(move(), throwsA(isA<RenameFailure>()));
      expect(writes, isEmpty);
      rows[0]['name_enc'] = bridge.sealName(handle, sibling, 'Cafe.txt');
      await move();
      expect(writes, hasLength(1));
      expect(writes.single, {
        'parent_id': destination, 'source_parent_id': null,
        'source_name_enc': sealed, 'siblings': [{'id': sibling, 'name_enc': rows[0]['name_enc']}],
      });
      expect(jsonEncode(writes), isNot(contains('Cafe')));
      for (final code in [409, 404]) {
        status = code;
        await expectLater(move(), throwsA(code == 409 ? isA<RenameFailure>() : isA<ApiException>()));
      }
      expect(writes, hasLength(3)); // no blind retry or legacy fallback
      bridge.lock(handle);
      final before = reads;
      await expectLater(move(), throwsA(isA<NativeException>()));
      expect(reads, before);
      expect(writes, hasLength(3));
    } finally {
      bridge.lock(handle);
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
