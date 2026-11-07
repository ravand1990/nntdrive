import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/file_rename.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('portable names reject traversal, device names and ambiguous suffixes',
      () {
    for (final name in [
      '',
      '.',
      '..',
      '../a',
      r'a\b',
      'a/b',
      'a:',
      'NUL.txt',
      'COM1',
      'lpt9.doc',
      'x.',
      ' x',
      'x ',
      'x\u0000',
      'x\n'
    ]) {
      expect(renameValidationError(name), isNotNull, reason: name);
    }
    expect(renameValidationError('é' * 128), isNotNull);
    expect(renameValidationError('a' * 255), isNull);
    for (final name in ['Report.pdf', 'Grüße.txt', '.hidden', 'COM10.txt']) {
      expect(renameValidationError(name), isNull);
    }
  });

  test(
      'rename sends only authenticated ciphertext and fails closed before PATCH',
      () async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('test password for rename');
    final handle = bridge.unlock(
            jsonEncode(keys['keyfile']), 'test password for rename')['handle']
        as int;
    const id = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const siblingId = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final sealed = bridge.sealName(handle, id, 'old.txt');
    final file = RemoteFile(id, null, sealed, false, 42, true, 7, 'version');
    var rows = <Map<String, dynamic>>[
      {'id': id, 'name_enc': sealed, 'revision': 7},
      {
        'id': siblingId,
        'name_enc': bridge.sealName(handle, siblingId, 'Taken.txt')
      },
    ];
    final patches = <Map<String, dynamic>>[];
    var renameStatus = HttpStatus.ok;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      expect(request.headers.value('authorization'), 'Bearer test-token');
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'GET') {
        request.response.write(jsonEncode({'files': rows}));
      } else {
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/v1/files/$id/rename');
        patches.add(jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, dynamic>);
        request.response.statusCode = renameStatus;
        request.response.write('{}');
      }
      await request.response.close();
    });
    final api = ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}', token: 'test-token');
    Future<void> rename(String name) =>
        renameRemoteEntry(api: api, handle: handle, file: file, name: name);
    try {
      await rename('Private new name.txt');
      expect(patches, hasLength(1));
      expect(patches.single.keys, ['name_enc', 'parent_id', 'siblings']);
      expect(patches.single['siblings'], [
        {'id': id, 'name_enc': sealed},
        {'id': siblingId, 'name_enc': rows[1]['name_enc']},
      ]);
      expect(jsonEncode(patches), isNot(contains('Private new name.txt')));
      final envelope = patches.single['name_enc'] as String;
      expect(bridge.openName(handle, id, envelope), 'Private new name.txt');
      expect(() => bridge.openName(handle, siblingId, envelope),
          throwsA(isA<NativeException>()));
      final foreignKeys = bridge.generateAccount('different account password');
      final foreignHandle = bridge.unlock(jsonEncode(foreignKeys['keyfile']),
          'different account password')['handle'] as int;
      try {
        expect(() => bridge.openName(foreignHandle, id, envelope),
            throwsA(isA<NativeException>()));
      } finally {
        bridge.lock(foreignHandle);
      }
      await expectLater(rename('TAKEN.TXT'), throwsA(isA<RenameFailure>()));
      await expectLater(rename('../bad'), throwsA(isA<RenameFailure>()));
      rows[0]['revision'] = 8;
      await expectLater(rename('another.txt'), throwsA(isA<RenameFailure>()));
      rows[0]['revision'] = 7;
      rows[1]['name_enc'] = 'invalid';
      await expectLater(rename('another.txt'), throwsA(isA<RenameFailure>()));
      rows = [];
      await expectLater(rename('another.txt'), throwsA(isA<RenameFailure>()));
      expect(patches, hasLength(1));
      rows = [
        {'id': id, 'name_enc': sealed, 'revision': 7}
      ];
      renameStatus = HttpStatus.conflict;
      await expectLater(rename('raced.txt'), throwsA(isA<RenameFailure>()));
      expect(patches, hasLength(2)); // No blind retry of a stale snapshot.
      renameStatus = HttpStatus.notFound;
      await expectLater(rename('old-server.txt'), throwsA(isA<ApiException>()));
      expect(patches, hasLength(3)); // No fallback to an unconditional PATCH.
      patches.clear();
      // A locked account cannot fall back to transmitting plaintext.
      bridge.lock(handle);
      rows = [
        {'id': id, 'name_enc': sealed, 'revision': 7}
      ];
      await expectLater(rename('locked.txt'), throwsA(isA<NativeException>()));
      expect(patches, isEmpty);
    } finally {
      bridge.lock(handle);
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
