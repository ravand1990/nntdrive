import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart' show Session;
import 'package:nntdrive/native.dart';
import 'package:nntdrive/search_status.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';

SearchEntry entry(String id, String? parent, String name, {bool dir = false}) =>
    SearchEntry(RemoteFile(id, parent, name, dir, 42, true, 1, null), name);

void main() {
  test(
      'all status filters combine off-isolate and history distinguishes status',
      () async {
    final entries = <String, SearchEntry>{
      for (final status
          in SearchStatus.values.where((s) => s != SearchStatus.all))
        status.name: entry(status.name, null, 'Report.PDF').withStatus(status),
    };
    for (final status in SearchStatus.values) {
      final filter = SearchFilter(
          text: 'report',
          extension: '.pdf',
          minSize: 40,
          maxSize: 45,
          favoritesOnly: true,
          kind: SearchKind.file,
          status: status);
      final ids = await runSearchQuery(entries, filter, 200);
      expect(ids.toSet(),
          status == SearchStatus.all ? entries.keys.toSet() : {status.name});
      expect(
          await runSearchQuery(
              entries, SearchFilter(text: 'absent', status: status), 200),
          isEmpty);
    }
    final index = AccountSearch(
        handle: 1,
        operations: SessionOperations(),
        list: (_) async => [],
        decrypt: (_) => '',
        authorize: () {});
    addTearDown(index.dispose);
    for (final save in [false, true]) {
      index.remember(const SearchFilter(status: SearchStatus.local),
          save: save);
      index.remember(const SearchFilter(status: SearchStatus.cloudOnly),
          save: save);
      index.remember(const SearchFilter(status: SearchStatus.local),
          save: save);
      expect((save ? index.saved : index.recent).map((f) => f.status),
          [SearchStatus.local, SearchStatus.cloudOnly]);
    }
  });

  test('owned inspector retains prior snapshot on failure and drains on close',
      () async {
    final operations = SessionOperations();
    final index = AccountSearch(
        handle: 1,
        operations: operations,
        list: (_) async => [entry('f', null, 'Report').file],
        decrypt: (f) => f.nameEnc,
        authorize: () {});
    addTearDown(index.dispose);
    await index.rebuild(
        inspectStatuses: (_, cancelled) async => {'f': SearchStatus.local});
    final revision = index.snapshotRevision;
    await expectLater(index.rebuild(inspectStatuses: (_, cancelled) async {
      throw StateError('private path diagnostic');
    }), throwsA(isA<SearchUnavailable>()));
    expect(index.snapshotRevision, revision);
    expect(
        (await index.search(const SearchFilter(status: SearchStatus.local)))
            .single
            .name,
        'Report');
    // Rebuild without an inspector must not reuse old status evidence.
    await index.rebuild();
    expect(
        await index.search(const SearchFilter(status: SearchStatus.cloudOnly)),
        isEmpty);
    expect(
        (await index.search(const SearchFilter(status: SearchStatus.unknown)))
            .length,
        1);
    final entered = Completer<void>();
    final gate = Completer<void>();
    final build =
        expectLater(index.rebuild(inspectStatuses: (_, cancelled) async {
      entered.complete();
      await gate.future;
      expect(cancelled(), isTrue);
      return {'f': SearchStatus.local};
    }), throwsA(isA<SearchUnavailable>()));
    await entered.future;
    index.close();
    var drained = false;
    final drain = operations.drain(1).then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    gate.complete();
    await build;
    await drain;
    expect(index.count, 0);
    expect(index.snapshotRevision, revision + 1);
  });

  test(
      'real filesystem statuses fail closed for links traversal and canonical ancestors',
      () async {
    final temporary = await Directory.systemTemp.createTemp('search-status-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    addTearDown(() => root.delete(recursive: true));
    final folder = SyncFolderConfig(
        id: 'sync', name: 'root', localPath: root.path, remoteRootId: 'root');
    var tree = <String, SearchEntry>{
      'root': entry('root', null, 'Root', dir: true),
      'local': entry('local', 'root', 'Report.pdf'),
      'missing': entry('missing', 'root', 'Missing.pdf'),
      'outside': entry('outside', null, 'Outside'),
    };
    await File('${root.path}/Report.pdf').writeAsString('local bytes');
    Future<Map<String, SearchStatus>> inspect() => inspectSearchStatuses(
        snapshot: tree,
        folders: [folder],
        comparisonKey: NativeBridge.instance.nameCollisionKey,
        cancelled: () => false);
    var statuses = await inspect();
    expect(statuses['local'], SearchStatus.local);
    expect(statuses['missing'], SearchStatus.cloudOnly);
    expect(statuses['outside'], SearchStatus.notCovered);
    folder.lastReport = {
      'item_errors': [
        {
          'operation': 'download',
          'code': 'io',
          'paths': ['Missing.pdf']
        }
      ]
    };
    statuses = await inspect();
    expect(statuses['local'], SearchStatus.local);
    expect(statuses['missing'], SearchStatus.error);
    folder.running = true;
    folder.progress = {'path': 'Report.pdf', 'complete': false};
    expect((await inspect())['local'], SearchStatus.syncing);
    folder.running = false;
    folder.conflictFiles = ['Report.pdf'];
    expect((await inspect())['local'], SearchStatus.conflict);
    // Windows symlink creation requires privileges not assumed by unit tests.
    if (!Platform.isWindows) {
      await File('${root.path}/Report.pdf').delete();
      await Link('${root.path}/Report.pdf').create('${root.path}/Missing.pdf');
      expect((await inspect())['local'], SearchStatus.error);
    }
    tree['traversal'] = entry('traversal', 'root', '../escape');
    expect((await inspect())['missing'], SearchStatus.unknown);
    tree.remove('traversal');
    tree['root-alias'] = entry('root-alias', null, 'root', dir: true);
    expect((await inspect())['missing'], SearchStatus.unknown);
    tree.remove('root-alias');
    tree['composed'] = entry('composed', 'root', 'é', dir: true);
    tree['decomposed'] = entry('decomposed', 'root', 'e\u0301', dir: true);
    tree['child'] = entry('child', 'composed', 'child');
    expect((await inspect())['child'], SearchStatus.unknown);
    expect((await inspect())['composed'], SearchStatus.unknown);
    expect((await inspect())['missing'], SearchStatus.error);
    tree.remove('decomposed');
    await Directory('${root.path}/é').create();
    await File('${root.path}/é/child').writeAsString('present');
    expect((await inspect())['child'], SearchStatus.local);
    if (!Platform.isWindows) {
      await Directory('${root.path}/é').delete(recursive: true);
      await Link('${root.path}/é').create(root.path);
      expect((await inspect())['child'], SearchStatus.error);
    }
    folder.excluded = ['Missing.pdf'];
    expect((await inspect())['missing'], SearchStatus.notCovered);
    await expectLater(
        inspectSearchStatuses(
            snapshot: tree,
            folders: [folder],
            comparisonKey: NativeBridge.instance.nameCollisionKey,
            cancelled: () => true),
        throwsA(isA<SearchUnavailable>()));
  });

  // Kept separate from testWidgets so real loopback HTTP is not overridden.
  test(
      'Session native HTTP index supplies status ancestry with no plaintext requests',
      () async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('status fixture');
    final handle = bridge.unlock(
        jsonEncode(keys['keyfile']), 'status fixture')['handle'] as int;
    const rootId = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    const fileId = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final temporary =
        await Directory.systemTemp.createTemp('search-http-status-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    await File('${root.path}/Private.pdf').writeAsString('local');
    final requests = <String>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((request) async {
      requests.add('${request.uri} ${await utf8.decoder.bind(request).join()}');
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'files': request.uri.queryParameters['parent_id'] == rootId
            ? [
                {
                  'id': fileId,
                  'parent_id': rootId,
                  'name_enc': bridge.sealName(handle, fileId, 'Private.pdf')
                }
              ]
            : [
                {
                  'id': rootId,
                  'is_dir': true,
                  'name_enc': bridge.sealName(handle, rootId, 'Private root')
                }
              ]
      }));
      await request.response.close();
    });
    final session = Session(
        server: 'http://127.0.0.1:${server.port}',
        token: 'fixture',
        handle: handle,
        accountId: 'fixture',
        email: 'fixture@example.invalid',
        operations: SessionOperations());
    try {
      await session.search.rebuild(
          inspectStatuses: (snapshot, cancelled) => inspectSearchStatuses(
              snapshot: snapshot,
              folders: [
                SyncFolderConfig(
                    id: 's',
                    name: 'local',
                    localPath: root.path,
                    remoteRootId: rootId)
              ],
              comparisonKey: bridge.nameCollisionKey,
              cancelled: cancelled));
      expect(
          (await session.search.search(const SearchFilter(
                  status: SearchStatus.local, kind: SearchKind.file)))
              .single
              .name,
          'Private.pdf');
      expect(requests.length, 2);
      expect(requests.join(), isNot(contains('Private')));
      expect(requests.join(), isNot(contains(root.path)));
    } finally {
      session.search.close();
      await session.operations.drain(handle);
      bridge.lock(handle);
      await server.close(force: true);
      await sub.cancel();
      await root.delete(recursive: true);
    }
  });
}
