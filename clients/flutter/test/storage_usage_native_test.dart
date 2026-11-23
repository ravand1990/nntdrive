import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/main.dart' show Session;
import 'package:nntdrive/native.dart';
import 'package:nntdrive/storage_usage.dart';

// Real HTTP/crypto belongs outside the testWidgets HTTP override isolate.
void main() {
  test(
    'Session dashboard snapshot follows opaque listings without plaintext requests',
    () async {
      final bridge = NativeBridge.instance;
      const password = 'storage fixture';
      final keys = bridge.generateAccount(password);
      final handle =
          bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
      const folder = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const id = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final sealedFolder = bridge.sealName(handle, folder, 'Private folder');
      final sealedName = bridge.sealName(handle, id, 'Private report.TXT');
      var size = 13;
      var deleted = false;
      var corrupt = false;
      final requests = <({String method, Uri uri, String body})>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        requests.add((
          method: request.method,
          uri: request.uri,
          body: await utf8.decoder.bind(request).join(),
        ));
        final parent = request.uri.queryParameters['parent_id'];
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'files': parent == null
                ? [
                    {'id': folder, 'name_enc': sealedFolder, 'is_dir': true},
                  ]
                : deleted
                ? []
                : [
                    {
                      'id': id,
                      'parent_id': folder,
                      'name_enc': corrupt ? sealedFolder : sealedName,
                      'size': size,
                    },
                  ],
          }),
        );
        await request.response.close();
      });
      final session = Session(
        server: 'http://127.0.0.1:${server.port}',
        token: 'fixture-token',
        email: 'fixture@example.invalid',
        accountId: 'fixture-account',
        handle: handle,
        operations: SessionOperations(),
      );
      try {
        await session.search.rebuild();
        var usage = await session.search.readSnapshot(runStorageUsage);
        expect(usage.bytes, 13);
        expect(usage.largest.single.path, 'Private folder/Private report.TXT');
        expect(usage.types.single.label, '.txt');
        size = 31; // Fresh listing models replace prior live size.
        await session.search.rebuild();
        expect((await session.search.readSnapshot(runStorageUsage)).bytes, 31);
        corrupt = true;
        await expectLater(session.search.rebuild(), throwsException);
        expect((await session.search.readSnapshot(runStorageUsage)).bytes, 31);
        corrupt = false;
        deleted = true;
        await session.search.rebuild();
        usage = await session.search.readSnapshot(runStorageUsage);
        expect(usage.bytes, 0);
        expect(usage.files, 0);
        expect(usage.folders.single.label, 'Private folder');
        for (final request in requests) {
          expect(request.method, 'GET');
          expect(request.uri.path, '/api/v1/files');
          expect(request.uri.queryParameters.keys, everyElement('parent_id'));
          expect(
            request.uri.queryParameters['parent_id'],
            anyOf(isNull, folder),
          );
          expect(request.body, isEmpty);
          expect(request.uri.toString(), isNot(contains('Private')));
        }
        final before = requests.length;
        bridge.lock(handle);
        await expectLater(
          session.search.readSnapshot(runStorageUsage),
          throwsException,
        );
        await expectLater(session.search.rebuild(), throwsException);
        expect(requests.length, before);
      } finally {
        session.search.close();
        await session.operations.drain(handle);
        bridge.lock(handle);
        await server.close(force: true);
        await subscription.cancel();
      }
    },
  );
}
