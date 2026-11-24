// Real HTTP/crypto: do not initialize a widget binding in this isolate.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart' show Session;
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/storage_usage.dart';

Future<void> published(AccountSearch index, int revision) async {
  final done = Completer<void>();
  void changed() {
    if (index.snapshotRevision >= revision && !done.isCompleted) {
      done.complete();
    }
  }

  index.addListener(changed);
  try {
    changed();
    await done.future.timeout(const Duration(seconds: 20));
  } finally {
    index.removeListener(changed);
  }
}

void main() {
  test(
    'Session native upload refreshes only after commit and drains suspended publication',
    () async {
      final bridge = NativeBridge.instance;
      const password = 'upload refresh fixture';
      final keys = bridge.generateAccount(password);
      final handle =
          bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
      const id = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const revision = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final name = bridge.sealName(handle, id, 'Private upload.txt');
      final scratch = await Directory.systemTemp.createTemp('upload-refresh-');
      final empty = await File('${scratch.path}/empty').writeAsBytes([]);
      var size = 7;
      var listings = 0;
      var reject = false;
      var entered = Completer<void>();
      var release = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'GET') {
          listings++;
          expect(request.uri.path, '/api/v1/files');
          request.response.write(
            jsonEncode({
              'files': [
                {'id': id, 'name_enc': name, 'size': size},
              ],
            }),
          );
        } else {
          expect(request.uri.path, '/api/v1/files/$id/versions');
          expect(body, isNot(contains('Private')));
          final commit = jsonDecode(body) as Map<String, dynamic>;
          expect(commit['sealed_manifest'], isA<String>());
          entered.complete();
          await release.future;
          if (reject) {
            request.response.statusCode = 409;
          } else {
            size = commit['size'] as int;
          }
          request.response.write('{}');
        }
        await request.response.close();
      });
      final session = Session(
        server: 'http://127.0.0.1:${server.port}',
        token: 'fixture-token',
        handle: handle,
        accountId: 'fixture',
        email: 'fixture@example.invalid',
        operations: SessionOperations(),
      );
      Future<Map<String, dynamic>> upload() => session.upload(
        fileId: id,
        revisionId: revision,
        parentRevision: '',
        path: empty.path,
      );
      try {
        await session.search.rebuild();
        final uploading = upload();
        await entered.future;
        expect(session.search.snapshotRevision, 1);
        expect(listings, 1);
        release.complete();
        await uploading;
        await published(session.search, 2);
        expect((await session.search.readSnapshot(runStorageUsage)).bytes, 0);
        final before = listings;
        entered = Completer<void>();
        release = Completer<void>()..complete();
        reject = true;
        await expectLater(upload(), throwsException);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(listings, before);
        expect(session.search.snapshotRevision, 2);
        reject = false;
        entered = Completer<void>();
        release = Completer<void>();
        final suspended = upload();
        await entered.future;
        session.search.close();
        var drained = false;
        final drain = session.operations
            .drain(handle)
            .then((_) => drained = true);
        await expectLater(upload(), throwsStateError);
        await Future<void>.delayed(Duration.zero);
        expect(drained, isFalse);
        release.complete();
        await suspended;
        await drain;
        expect(listings, before);
        expect(session.search.count, 0);
      } finally {
        if (!release.isCompleted) release.complete();
        session.search.close();
        await session.operations.drain(handle);
        await bridge.drainSession(handle);
        bridge.lock(handle);
        await server.close(force: true);
        await subscription.cancel();
        await scratch.delete(recursive: true);
      }
    },
  );
  test(
    'acknowledged namespace writes refresh real Session RAM with opaque-only HTTP',
    () async {
      final bridge = NativeBridge.instance;
      const password = 'mutation fixture';
      final keys = bridge.generateAccount(password);
      final handle =
          bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
      const id = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      var name = bridge.sealName(handle, id, 'Private document.txt');
      var size = 13;
      var deleted = false;
      var reject = false;
      var corrupt = false;
      final requests = <({String method, Uri uri, String body})>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        requests.add((method: request.method, uri: request.uri, body: body));
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'GET') {
          request.response.write(
            jsonEncode({
              'files': deleted
                  ? []
                  : [
                      {
                        'id': id,
                        'name_enc': corrupt ? 'broken' : name,
                        'size': size,
                      },
                    ],
            }),
          );
        } else if (reject) {
          request.response.statusCode = 409;
          request.response.write('{"error":"conflict"}');
        } else {
          final data = body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(body) as Map<String, dynamic>;
          if (data['deleted'] == true) deleted = true;
          if (request.uri.path.endsWith('/restore')) deleted = false;
          if (data['name_enc'] is String) name = data['name_enc'] as String;
          request.response.write('{}');
        }
        await request.response.close();
      });
      final session = Session(
        server: 'http://127.0.0.1:${server.port}',
        token: 'fixture-token',
        handle: handle,
        accountId: 'fixture',
        email: 'fixture@example.invalid',
        operations: SessionOperations(),
      );
      final api = session.bindApi(
        ApiClient(baseUrl: session.server, token: session.token),
      );
      try {
        await session.search.rebuild();
        expect((await session.search.readSnapshot(runStorageUsage)).bytes, 13);
        await api.deleteFile(id);
        await published(session.search, 2);
        expect((await session.search.readSnapshot(runStorageUsage)).files, 0);
        size = 31;
        await api.restoreFile(id);
        await published(session.search, 3);
        expect((await session.search.readSnapshot(runStorageUsage)).bytes, 31);
        final sealed = bridge.sealName(handle, id, 'Private renamed.bin');
        await api.renameFile(id, sealed, parentId: null, siblings: []);
        await published(session.search, 4);
        expect(
          (await session.search.readSnapshot(
            runStorageUsage,
          )).types.single.label,
          '.bin',
        );
        final before = session.search.snapshotRevision;
        reject = true;
        await expectLater(api.deleteFile(id), throwsA(isA<ApiException>()));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(session.search.snapshotRevision, before);
        reject = false;
        corrupt = true;
        await api.setFavorite(id, true);
        // Await the shared queue rather than initiating a second build.
        await session.search.refreshAfterMutation();
        expect(session.search.failed, isTrue);
        expect(session.search.snapshotRevision, before);
        expect((await session.search.readSnapshot(runStorageUsage)).bytes, 31);
        corrupt = false;
        await api.setFavorite(id, false);
        await published(session.search, before + 1);
        for (final request in requests) {
          expect('${request.uri} ${request.body}', isNot(contains('Private')));
          expect('${request.uri} ${request.body}', isNot(contains('.bin')));
          if (request.method == 'GET') {
            expect(request.uri.path, '/api/v1/files');
            expect(request.uri.queryParameters, isEmpty);
            expect(request.body, isEmpty);
          }
        }
        session.search.close();
        await session.operations.drain(handle);
        final count = requests.length;
        session.accountChanged();
        await Future<void>.delayed(Duration.zero);
        expect(requests.length, count);
      } finally {
        session.search.close();
        await session.operations.drain(handle);
        bridge.lock(handle);
        await server.close(force: true);
        await subscription.cancel();
      }
    },
  );

  test(
    'all Dart namespace/content publishers notify only after acknowledged success',
    () async {
      var notifications = 0;
      var reject = false;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.statusCode = reject ? 409 : 200;
        request.response.write('{}');
        await request.response.close();
      });
      final api = ApiClient(
        baseUrl: 'http://127.0.0.1:${server.port}',
        token: 'fixture',
      )..onAccountChanged = () => notifications++;
      final file = RemoteFile(
        'opaque',
        null,
        'ciphertext',
        false,
        1,
        false,
        1,
        'revision',
      );
      final writes = <Future<void> Function()>[
        () => api.createFile(
          id: file.id,
          parentId: null,
          nameEnc: file.nameEnc,
          isDir: false,
        ),
        () => api.bootstrapRoot(
          kind: 'global',
          nodeId: file.id,
          nameEnc: file.nameEnc,
        ),
        () => api.deleteFile(file.id),
        () => api.restoreFile(file.id),
        () => api.purgeFile(file.id),
        () => api.emptyTrash(),
        () async {
          await api.rewind(before: DateTime.utc(2020), items: []);
        },
        () => api.setFavorite(file.id, true),
        () => api.renameFile(file.id, 'sealed', parentId: null, siblings: []),
        () => api.moveFileChecked(file, null, []),
        () => api.moveFile(file.id, null),
        () async {
          await api.restoreVersion(file.id, 'revision');
        },
      ];
      try {
        for (var i = 0; i < writes.length; i++) {
          await writes[i]();
          expect(notifications, i + 1);
        }
        reject = true;
        for (final write in writes) {
          await expectLater(write(), throwsA(isA<ApiException>()));
        }
        expect(notifications, writes.length);
        reject = false;
        await api.keyfile(); // Read-only traffic never invalidates.
        expect(notifications, writes.length);
      } finally {
        await server.close(force: true);
        await subscription.cancel();
      }
    },
  );
}
