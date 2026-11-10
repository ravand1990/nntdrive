import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';

// No testWidgets binding here: exercise real HTTP and the actual native crypto.
void main() {
  test(
      'native nested index and offline query send no plaintext; revoked handle fails closed',
      () async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('search fixture password');
    final handle = bridge.unlock(
      jsonEncode(keys['keyfile']),
      'search fixture password',
    )['handle'] as int;
    const folder = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const file = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const secret = 'ConfidentialSearchNeedle.pdf';
    final sealedFolder = bridge.sealName(handle, folder, 'Private directory');
    final sealedFile = bridge.sealName(handle, file, secret);
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      requests.add(
        '${request.method} ${request.uri} ${await utf8.decoder.bind(request).join()}',
      );
      request.response.headers.contentType = ContentType.json;
      request.response.write(
        jsonEncode({
          'files': request.uri.queryParameters['parent_id'] == folder
              ? [
                  {
                    'id': file,
                    'parent_id': folder,
                    'name_enc': sealedFile,
                    'size': 42,
                    'favorite': true,
                    'updated_at': '2026-01-02T00:00:00Z',
                  },
                ]
              : [
                  {'id': folder, 'name_enc': sealedFolder, 'is_dir': true},
                ],
        }),
      );
      await request.response.close();
    });
    final api = ApiClient(
      baseUrl: 'http://127.0.0.1:${server.port}',
      token: 'fixture-token',
    );
    final index = AccountSearch(
      handle: handle,
      operations: SessionOperations(),
      list: (p) => api.listFiles(parentId: p),
      decrypt: (f) => bridge.openName(handle, f.id, f.nameEnc),
      authorize: () {
        bridge.sealName(handle, folder, '');
      },
    );
    try {
      await index.rebuild();
      expect(index.count, 2);
      await server.close(force: true);
      final found = await index.search(
        const SearchFilter(
          text: 'ConfidentialSearchNeedle',
          favoritesOnly: true,
          minSize: 40,
          maxSize: 50,
        ),
      );
      expect(found.single.name, secret);
      expect(index.folderPath(found.single), '/Private directory');
      expect(requests, [
        'GET /api/v1/files ',
        'GET /api/v1/files?parent_id=$folder ',
      ]);
      expect(requests.join(), isNot(contains(secret)));
      expect(requests.join(), isNot(contains('Private directory')));
      expect(found.single.file.updatedAt, DateTime.utc(2026, 1, 2));
      bridge.lock(handle);
      await expectLater(
        index.search(const SearchFilter(text: secret)),
        throwsA(isA<SearchUnavailable>()),
      );
      index.close();
      expect(index.count, 0);
    } finally {
      index.dispose();
      bridge.lock(handle);
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
