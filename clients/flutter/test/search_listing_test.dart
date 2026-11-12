import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart' show Session;
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';

// Deliberately separate from testWidgets: no synthetic HTTP override.
class WorkerOnlyBytes extends ListBase<int> {
  WorkerOnlyBytes(this.bytes) : caller = Isolate.current.hashCode;
  final List<int> bytes;
  final int caller;
  void check() {
    if (Isolate.current.hashCode == caller) {
      throw StateError('listing decode ran on caller isolate');
    }
  }

  @override
  int get length {
    check();
    return bytes.length;
  }

  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  int operator [](int index) {
    check();
    return bytes[index];
  }

  @override
  void operator []=(int index, int value) =>
      throw UnsupportedError('immutable');
}

void main() {
  test('listing helper decodes and constructs models only on worker isolate',
      () async {
    final files =
        await runSearchListingDecode(WorkerOnlyBytes(utf8.encode(jsonEncode({
      'files': [
        {
          'id': 'opaque',
          'name_enc': 'sealed',
          'size': 42,
          'favorite': true,
          'updated_at': '2026-01-02T00:00:00Z'
        }
      ]
    }))));
    expect(files.single.id, 'opaque');
    expect(files.single.size, 42);
    expect(files.single.favorite, isTrue);
    expect(files.single.updatedAt, DateTime.utc(2026, 1, 2));
  });

  test(
      'listing helper rejects malformed UTF8 JSON models and entry overflow without diagnostics',
      () async {
    for (final bytes in <List<int>>[
      [0xff],
      utf8.encode('private malformed'),
      utf8.encode('{}'),
      utf8.encode('{"files":{}}'),
      utf8.encode('{"files":[{"id":42}]}'),
      utf8.encode(jsonEncode({
        'files': List.filled(100001, {'id': 'opaque'})
      })),
    ]) {
      await expectLater(
          runSearchListingDecode(bytes),
          throwsA(predicate((Object e) =>
              e is ApiException &&
              e.code == 'search_listing' &&
              e.message == 'Search listing unavailable')));
    }
  });

  test('listing helper accepts the complete 100k-entry account bound',
      () async {
    final files = await runSearchListingDecode(utf8.encode(jsonEncode({
      'files': List.filled(searchListingMaxFiles, {'id': 'opaque'})
    })));
    expect(files.length, searchListingMaxFiles);
  });

  test(
      'bounded streamed HTTP listing keeps auth and redacts errors; legacy list unchanged',
      () async {
    var mode = 'valid';
    final auth = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      auth.add(request.headers.value('authorization'));
      final response = request.response;
      if (mode == 'http') {
        response.statusCode = 403;
        response.write('{"error":"private-code","message":"private-token"}');
      } else if (mode == 'length') {
        response.contentLength = 1024;
        response.add(List.filled(1024, 32));
      } else if (mode == 'chunked') {
        // No Content-Length; reject based on actual bytes, not headers alone.
        response.add(List.filled(512, 32));
        await response.flush();
        response.add(List.filled(513, 32));
      } else {
        response.write('{"files":[{"id":"opaque"}]}');
      }
      try {
        await response.close();
      } catch (_) {/* client rejects oversized bodies */}
    });
    final api =
        ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'fixture');
    final validBody = utf8.encode('{"files":[{"id":"opaque"}]}');
    expect(
        (await api.listFilesForSearch(maxBodyBytes: validBody.length))
            .single
            .id,
        'opaque');
    var parsedOversize = false;
    Future<List<RemoteFile>> unexpectedParse(List<int> bytes) async {
      parsedOversize = true;
      return runSearchListingDecode(bytes);
    }

    await expectLater(
        api.listFilesForSearch(maxBodyBytes: searchListingMaxBodyBytes + 1),
        throwsA(isA<ApiException>()));
    mode = 'length';
    await expectLater(
        api.listFilesForSearch(maxBodyBytes: 1023, decode: unexpectedParse),
        throwsA(isA<ApiException>()));
    mode = 'chunked';
    await expectLater(
        api.listFilesForSearch(maxBodyBytes: 1024, decode: unexpectedParse),
        throwsA(isA<ApiException>()));
    expect(parsedOversize, isFalse);
    mode = 'http';
    try {
      await api.listFilesForSearch();
      fail('expected HTTP failure');
    } on ApiException catch (e) {
      expect(e.status, 403);
      expect(e.toString(), isNot(contains('private')));
    }
    // Unrelated callers retain the pre-existing response/error contract.
    await expectLater(
        api.listFiles(),
        throwsA(predicate((Object e) =>
            e is ApiException &&
            e.code == 'private-code' &&
            e.message == 'private-token')));
    expect(auth, everyElement('Bearer fixture'));
  });

  test(
      'actual native Session traverses bounded listings and retains snapshot after malformed refresh',
      () async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('listing fixture');
    final handle = bridge.unlock(
        jsonEncode(keys['keyfile']), 'listing fixture')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const folder = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const file = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final folderEnc = bridge.sealName(handle, folder, 'Private folder');
    final fileEnc = bridge.sealName(handle, file, 'Private leaf.pdf');
    var malformed = false;
    var oversized = false;
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      requests.add(
          '${request.method} ${request.uri} ${await utf8.decoder.bind(request).join()}');
      expect(request.headers.value('authorization'), 'Bearer fixture');
      if (oversized) {
        // Send just oversized headers: the real Session must reject before
        // waiting for/allocating the advertised body or invoking its decoder.
        request.response.contentLength = searchListingMaxBodyBytes + 1;
        await request.response.flush();
        try {
          await request.response.close();
        } catch (_) {/* truncated on purpose */}
        return;
      }
      request.response.write(malformed
          ? 'private malformed'
          : jsonEncode({
              'files': request.uri.queryParameters['parent_id'] == folder
                  ? [
                      {'id': file, 'parent_id': folder, 'name_enc': fileEnc}
                    ]
                  : [
                      {'id': folder, 'name_enc': folderEnc, 'is_dir': true}
                    ]
            }));
      await request.response.close();
    });
    final session = Session(
        server: 'http://127.0.0.1:${server.port}',
        token: 'fixture',
        handle: handle,
        accountId: 'fixture',
        email: 'fixture',
        operations: SessionOperations());
    addTearDown(session.search.dispose);
    expect(session.searchListingWorker, same(runSearchListingDecode));
    await session.search.rebuild();
    expect(session.search.count, 2);
    final found =
        (await session.search.search(const SearchFilter(text: 'leaf'))).single;
    expect(session.search.folderPath(found), '/Private folder');
    expect(requests,
        ['GET /api/v1/files ', 'GET /api/v1/files?parent_id=$folder ']);
    malformed = true;
    await expectLater(
        session.search.rebuild(), throwsA(isA<SearchUnavailable>()));
    expect(session.search.count, 2);
    expect(
        (await session.search.search(const SearchFilter(text: 'leaf')))
            .single
            .name,
        'Private leaf.pdf');
    oversized = true;
    await expectLater(
        session.search.rebuild().timeout(const Duration(seconds: 5)),
        throwsA(isA<SearchUnavailable>()));
    expect(session.search.count, 2);
    expect(requests.join(), isNot(contains('Private')));
    bridge.lock(handle);
    final before = requests.length;
    await expectLater(
        session.search.rebuild(), throwsA(isA<SearchUnavailable>()));
    expect(requests.length, before);
  });

  test(
      'Session close discards delayed listing parse but drain owns its completion',
      () async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('listing drain');
    final handle = bridge.unlock(
        jsonEncode(keys['keyfile']), 'listing drain')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('{"files":[]}');
      await request.response.close();
    });
    final entered = Completer<void>();
    final release = Completer<void>();
    final operations = SessionOperations();
    final session = Session(
        server: 'http://127.0.0.1:${server.port}',
        token: 'fixture',
        handle: handle,
        accountId: 'fixture',
        email: 'fixture',
        operations: operations,
        searchListingWorker: (bytes) async {
          final worker = runSearchListingDecode(bytes);
          entered.complete();
          final files = await worker;
          await release.future;
          return files;
        });
    addTearDown(session.search.dispose);
    final rejected = expectLater(
        session.search.rebuild(), throwsA(isA<SearchUnavailable>()));
    await entered.future.timeout(const Duration(seconds: 5));
    session.search.close();
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
    expect(session.search.ready, isFalse);
    expect(session.search.count, 0);
    await expectLater(
        session.search.rebuild(), throwsA(isA<SearchUnavailable>()));
  });
}
