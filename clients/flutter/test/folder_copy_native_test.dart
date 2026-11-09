// Real native worker-isolate crypto + loopback HTTP, no widget HTTP override.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/file_copy.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('native folder Copy prepares one bounded tree, reseals children and never retries', () async {
    final bridge = NativeBridge.instance;
    const password = 'folder fixture password';
    final keys = bridge.generateAccount(password);
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
    const root = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const nested = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const empty = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const file = '3b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const revision = '4b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const destination = '5b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    Map<String, dynamic> snapshot(String id, String? parent, String name, bool dir) => {
      'id': id, 'parent_id': parent, 'name_enc': bridge.sealName(handle, id, name),
      'is_dir': dir, 'size': 0, 'current_version': dir ? null : revision,
    };
    final nodes = [snapshot(root, null, 'Café folder', true),
      snapshot(nested, root, 'nested', true), snapshot(empty, root, 'empty', true),
      snapshot(file, nested, 'file', false)];
    final source = RemoteFile(root, null, nodes.first['name_enc'] as String, true, 0, false, 1, null);
    var manifest = <int>[];
    final writes = <Map<String, dynamic>>[];
    var reads = 0;
    var status = 201;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer fixture-token');
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/versions')) {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        manifest = base64Decode(body['sealed_manifest'] as String);
        request.response.write('{}');
      } else if (request.uri.path.endsWith('/copy-tree-snapshot')) {
        reads++;
        expect(request.uri.path, '/api/v1/files/$root/copy-tree-snapshot');
        request.response.write(jsonEncode(nodes));
      } else if (request.uri.path.endsWith('/manifest')) {
        reads++;
        final id = request.uri.path.split('/')[4];
        final original = id == file;
        final copied = original ? null : (writes.first['nodes'] as List).cast<Map<String, dynamic>>()
          .singleWhere((n) => n['id'] == id);
        request.response.headers.set('x-nntdrive-revision', original ? revision : copied!['revision_id'] as String);
        request.response.add(original ? manifest : base64Decode(copied!['sealed_manifest'] as String));
      } else if (request.method == 'GET') {
        reads++;
        expect(request.uri.queryParameters['parent_id'], destination);
        request.response.write('{"files":[]}');
      } else {
        expect(request.uri.path, '/api/v1/files/$root/copy-tree-checked');
        writes.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>);
        if (status == 0) {
          final socket = await request.response.detachSocket(writeHeaders: false);
          socket.destroy();
          return;
        }
        request.response.statusCode = status;
        request.response.write(status == 201 ? '{}' : '{"error":"private fixture-token diagnostic"}');
      }
      await request.response.close();
    });
    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'fixture-token');
    final dir = await Directory.systemTemp.createTemp('folder-copy-native-');
    final input = await File('${dir.path}/in').writeAsBytes([]);
    Future<Map<String, dynamic>> copy({int? using, String? parent = destination}) => copyRemoteFile(
      api: api, handle: using ?? handle, file: source, parentId: parent);
    try {
      await bridge.uploadAsync(handle: handle, baseUrl: api.baseUrl, token: api.token!,
        fileId: file, revisionId: revision, parentRevision: '', path: input.path);
      final result = await copy();
      expect(writes, hasLength(1));
      expect(result['revision_id'], isNull);
      final body = writes.single;
      expect(body['source'], nodes);
      expect(body['parent_id'], destination);
      expect(body['siblings'], isEmpty);
      final prepared = (body['nodes'] as List).cast<Map<String, dynamic>>();
      expect(prepared, hasLength(4));
      expect(result['id'], prepared.singleWhere((n) => n['source_id'] == root)['id']);
      expect(prepared.map((n) => n['id']).toSet(), hasLength(4));
      for (final n in prepared) {
        expect(nodes.map((s) => s['id']), isNot(contains(n['id'])));
        final original = nodes.singleWhere((s) => s['id'] == n['source_id']);
        expect(n['name_enc'], isNot(original['name_enc']));
        expect(bridge.openName(handle, n['id'] as String, n['name_enc'] as String),
          bridge.openName(handle, original['id'] as String, original['name_enc'] as String));
        if (original['is_dir'] == true) {
          expect(n['revision_id'], isNull);
          expect(n['sealed_manifest'], isNull);
        } else {
          expect(n['revision_id'], isNot(revision));
          expect(n['sealed_manifest'], isNot(base64Encode(manifest)));
          await bridge.downloadAsync(handle: handle, baseUrl: api.baseUrl, token: api.token!,
            fileId: n['id'] as String, revisionId: n['revision_id'] as String,
            destination: '${dir.path}/out');
          expect(await File('${dir.path}/out').readAsBytes(), isEmpty);
        }
        expect(n['chunk_ids'], isEmpty);
      }
      expect(jsonEncode(body), isNot(contains('Café')));
      final savedName = nodes[2]['name_enc'];
      nodes[2]['name_enc'] = bridge.sealName(handle, empty, 'NESTED');
      await expectLater(copy(), throwsA(isA<NativeException>()));
      nodes[2]['name_enc'] = 'unreadable';
      await expectLater(copy(), throwsA(isA<NativeException>()));
      nodes[2]['name_enc'] = savedName;
      await expectLater(copy(parent: nested), throwsA(isA<NativeException>()));
      expect(writes, hasLength(1));
      for (final code in [409, 404, 500, 0]) {
        status = code;
        await expectLater(copy(), throwsA(isA<NativeException>().having((e) => e.message, 'secret-free ambiguity',
          allOf(contains('Refresh'), isNot(contains('fixture-token')), isNot(contains('diagnostic'))))));
      }
      expect(writes, hasLength(5)); // exactly one request per explicit attempt
      final other = bridge.generateAccount(password);
      final wrong = bridge.unlock(jsonEncode(other['keyfile']), password)['handle'] as int;
      final before = reads;
      await expectLater(copy(using: wrong), throwsA(isA<NativeException>()));
      bridge.lock(wrong);
      bridge.lock(handle);
      await expectLater(copy(), throwsA(isA<NativeException>()));
      expect(reads, before);
      expect(writes, hasLength(5));
    } finally {
      bridge.lock(handle);
      await server.close(force: true);
      await subscription.cancel();
      await dir.delete(recursive: true);
    }
  });
}
