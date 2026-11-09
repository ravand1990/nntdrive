// Real loopback HTTP + native crypto. Never initialize a widget binding here.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/file_copy.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('native Copy reseals metadata, guards names and fails closed without retry', () async {
    final bridge = NativeBridge.instance;
    const password = 'copy fixture password';
    final keys = bridge.generateAccount(password);
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
    const id = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const revision = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const destination = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const sibling = '3b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final source = RemoteFile(id, null, bridge.sealName(handle, id, 'Cafe\u0301.txt'), false, 0, false, 1, revision);
    var manifest = <int>[];
    var rows = <Map<String, dynamic>>[];
    final writes = <Map<String, dynamic>>[];
    var status = 201;
    var reads = 0;
    var corrupt = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer fixture-token');
      request.response.headers.contentType = ContentType.json;
      if (request.uri.path.endsWith('/versions')) {
        final body = jsonDecode(await utf8.decoder.bind(request).join());
        manifest = base64Decode(body['sealed_manifest'] as String);
        request.response.write('{}');
      } else if (request.uri.path.endsWith('/manifest')) {
        reads++;
        final copied = request.uri.path != '/api/v1/files/$id/manifest';
        final servedRevision = copied ? writes.first['revision_id'] : revision;
        expect(request.uri.queryParameters['revision'], servedRevision);
        request.response.headers.set('x-nntdrive-revision', servedRevision as String);
        request.response.add(corrupt ? [1, 2, 3] : copied
          ? base64Decode(writes.first['sealed_manifest'] as String) : manifest);
      } else if (request.method == 'GET') {
        reads++;
        expect(request.uri.queryParameters['parent_id'], destination);
        request.response.write(jsonEncode({'files': rows}));
      } else {
        expect(request.uri.path, '/api/v1/files/$id/copy-checked');
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
    final dir = await Directory.systemTemp.createTemp('copy-native-');
    final empty = await File('${dir.path}/empty').writeAsBytes([]);
    Future<Map<String, dynamic>> copy({int? using, RemoteFile? file}) => copyRemoteFile(
      api: api, handle: using ?? handle, file: file ?? source, parentId: destination);
    try {
      await bridge.uploadAsync(handle: handle, baseUrl: api.baseUrl, token: api.token!,
        fileId: id, revisionId: revision, parentRevision: '', path: empty.path);
      expect(manifest, isNotEmpty);
      final result = await copy();
      expect(writes, hasLength(1));
      final body = writes.single;
      expect(result['id'], body['id']);
      expect(result['revision_id'], body['revision_id']);
      expect(body['id'], isNot(id));
      expect(body['revision_id'], isNot(revision));
      expect(body['sealed_manifest'], isNot(base64Encode(manifest)));
      expect(body['name_enc'], isNot(source.nameEnc));
      expect(bridge.openName(handle, body['id'] as String, body['name_enc'] as String), 'Cafe\u0301.txt');
      expect(body['source_revision'], revision);
      expect(body['source_name_enc'], source.nameEnc);
      expect(body['source_parent_id'], isNull);
      expect(body['parent_id'], destination);
      expect(body['chunk_ids'], isEmpty);
      expect(body['siblings'], isEmpty);
      expect(jsonEncode(body), isNot(contains('Cafe')));
      final downloaded = '${dir.path}/copied';
      await bridge.downloadAsync(handle: handle, baseUrl: api.baseUrl, token: api.token!,
        fileId: body['id'] as String, revisionId: body['revision_id'] as String,
        destination: downloaded);
      expect(await File(downloaded).readAsBytes(), isEmpty);
      rows = [{'id': sibling, 'parent_id': destination,
        'name_enc': bridge.sealName(handle, sibling, 'CAFÉ.TXT'),
        'is_dir': false, 'size': 0, 'favorite': false, 'revision': 1, 'current_version': null}];
      await expectLater(copy(), throwsA(isA<NativeException>()));
      expect(writes, hasLength(1));
      rows[0]['name_enc'] = 'broken';
      await expectLater(copy(), throwsA(isA<NativeException>()));
      expect(writes, hasLength(1));
      rows[0]['name_enc'] = bridge.sealName(handle, sibling, 'Cafe.txt');
      await copy();
      expect(writes.last['siblings'], [{'id': sibling, 'name_enc': rows[0]['name_enc']}]);
      expect(writes.last['id'], isNot(body['id']));
      expect(writes.last['revision_id'], isNot(body['revision_id']));
      rows = [];
      corrupt = true;
      await expectLater(copy(), throwsA(isA<NativeException>()));
      expect(writes, hasLength(2));
      corrupt = false;
      final other = bridge.generateAccount(password);
      final wrong = bridge.unlock(jsonEncode(other['keyfile']), password)['handle'] as int;
      final before = reads;
      await expectLater(copy(using: wrong), throwsA(isA<NativeException>()));
      bridge.lock(wrong);
      expect(reads, before);
      for (final code in [409, 404, 500]) {
        status = code;
        await expectLater(copy(), throwsA(isA<NativeException>().having((e) => e.message, 'safe error',
          allOf(contains('Refresh'), isNot(contains('fixture-token')), isNot(contains('diagnostic'))))));
      }
      expect(writes, hasLength(5)); // one request per attempt, no legacy fallback
      status = 0; // request accepted, connection lost before any acknowledgement
      await expectLater(copy(), throwsA(isA<NativeException>().having((e) => e.message,
        'ambiguous outcome', contains('lost response may already have committed'))));
      expect(writes, hasLength(6));
      final noHttp = reads;
      await expectLater(copy(file: RemoteFile(id, null, source.nameEnc, false, 0, false, 1, null)),
        throwsA(isA<NativeException>()));
      await expectLater(copy(file: RemoteFile(sibling, null, source.nameEnc, false, 0, false, 1, revision)),
        throwsA(isA<NativeException>()));
      expect(reads, noHttp);
      bridge.lock(handle);
      final lockedReads = reads;
      await expectLater(copy(), throwsA(isA<NativeException>()));
      expect(reads, lockedReads);
      expect(writes, hasLength(6));
    } finally {
      bridge.lock(handle);
      await server.close(force: true);
      await subscription.cancel();
      await dir.delete(recursive: true);
    }
  });
}
