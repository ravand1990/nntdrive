import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/main.dart' show Session;
import 'package:nntdrive/session_operations.dart';

// No testWidgets binding here: exercise real HTTP and the actual native crypto.
void main() {
  test(
      'real worker opens ordered names, yields, authenticates and bounds batches',
      () async {
    final bridge = NativeBridge.instance;
    const password = 'worker search fixture';
    final keys = bridge.generateAccount(password);
    final handle =
        bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
    final foreignKeys = bridge.generateAccount(password);
    final wrong = bridge.unlock(
        jsonEncode(foreignKeys['keyfile']), password)['handle'] as int;
    addTearDown(() {
      bridge.lock(handle);
      bridge.lock(wrong);
    });
    const id = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const other = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final batch = [
      (id: id, nameEnc: bridge.sealName(handle, id, 'Secret α.txt')),
      (id: other, nameEnc: bridge.sealName(handle, other, 'Private β.pdf')),
    ];
    var eventRan = false;
    Timer.run(() => eventRan = true);
    expect(await bridge.openNamesAsync(handle, batch),
        ['Secret α.txt', 'Private β.pdf']);
    // A synchronous FFI loop wrapped in an async Future does not yield to this
    // event. This is a scheduling regression, not a cold-build performance claim.
    expect(eventRan, isTrue);
    final redacted = throwsA(predicate((Object e) =>
        e is NativeException && e.toString() == 'Encrypted names unavailable'));
    await expectLater(bridge.openNamesAsync(wrong, batch), redacted);
    await expectLater(
        bridge.openNamesAsync(
            handle, [(id: other, nameEnc: batch.first.nameEnc)]),
        redacted);
    await expectLater(
        bridge.openNamesAsync(
            handle, [(id: id, nameEnc: 'invalid private envelope')]),
        redacted);
    expect(
        (await bridge.openNamesAsync(handle, List.filled(128, batch.first)))
            .length,
        128);
    await expectLater(
        bridge.openNamesAsync(handle, List.filled(129, batch.first)), redacted);
    await expectLater(bridge.openNamesAsync(handle, []), redacted);
    bridge.lock(wrong);
    await expectLater(bridge.openNamesAsync(wrong, batch), redacted);
    await bridge.drainSession(handle);
    await expectLater(bridge.openNamesAsync(handle, batch), redacted);
  });

  test('real worker completion remains build-owned through delayed close/drain',
      () async {
    final bridge = NativeBridge.instance;
    const password = 'drain search fixture';
    final keys = bridge.generateAccount(password);
    final handle =
        bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const id = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final envelope = bridge.sealName(handle, id, 'Private late result');
    final operations = SessionOperations();
    final entered = Completer<void>();
    final release = Completer<void>();
    final index = AccountSearch(
      handle: handle,
      operations: operations,
      list: (_) async =>
          [RemoteFile(id, null, envelope, false, 0, false, 1, null)],
      decrypt: (_) => throw StateError('sync path used'),
      decryptBatch: (files) async {
        final worker = bridge.openNamesAsync(
            handle, files.map((f) => (id: f.id, nameEnc: f.nameEnc)).toList());
        entered.complete(); // Close while worker completion is still pending.
        final names = await worker;
        await release.future;
        return names;
      },
      authorize: () {
        bridge.sealName(handle, id, '');
      },
    );
    addTearDown(index.dispose);
    final rejected =
        expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
    await entered.future.timeout(const Duration(seconds: 5));
    index.close();
    var drained = false;
    final drain = operations.drain(handle).then((_) {
      drained = true;
      bridge.lock(handle);
    });
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    release.complete();
    await rejected;
    await drain;
    expect(index.count, 0);
    expect(index.ready, isFalse);
    await expectLater(
        bridge.openNamesAsync(handle, [(id: id, nameEnc: envelope)]),
        throwsA(isA<NativeException>()));
  });

  test('actual Session installs worker batch decryption', () {
    final session = Session(
        server: 'http://127.0.0.1',
        token: 'fixture',
        handle: 0,
        accountId: 'fixture',
        email: 'fixture',
        operations: SessionOperations());
    expect(session.search.decryptBatch, isNotNull);
    session.search.dispose();
  });

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
    final session = Session(
      server: 'http://127.0.0.1:${server.port}',
      token: 'fixture-token',
      handle: handle,
      accountId: 'fixture-account',
      email: 'fixture@example.invalid',
      operations: SessionOperations(),
    );
    final index = session.search;
    try {
      await index.rebuild();
      expect(index.count, 2);
      await server.close(force: true);
      var queryEventRan = false;
      Timer.run(() => queryEventRan = true);
      final found = await index.search(
        const SearchFilter(
          text: 'ConfidentialSearchNeedle',
          favoritesOnly: true,
          minSize: 40,
          maxSize: 50,
        ),
      );
      // Real Session + native encrypted HTTP build, not an injected runner.
      // A tiny scan must yield too: the old cooperative scan never did here.
      expect(queryEventRan, isTrue);
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
