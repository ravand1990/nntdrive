import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/conflict_paths.dart';
import 'package:nntdrive/search_status.dart';
import 'package:nntdrive/search_status_ancestry.dart';
import 'package:nntdrive/search_status_filesystem.dart';
import 'package:nntdrive/session_operations.dart';

class WorkerOnlyBatch extends ListBase<SearchStatusAncestry> {
  WorkerOnlyBatch(this.entries) : caller = Isolate.current.controlPort;
  final List<SearchStatusAncestry> entries;
  final SendPort caller;
  @override
  int get length => entries.length;
  @override
  set length(int value) => throw UnsupportedError('resize');
  @override
  SearchStatusAncestry operator [](int index) {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Filesystem batch read on caller');
    }
    return entries[index];
  }

  @override
  void operator []=(int index, SearchStatusAncestry value) =>
      throw UnsupportedError('write');
}

SearchStatusAncestry item(String id, String name, {bool dir = false}) => (
  id: id,
  isDir: dir,
  ancestry: [(id: 'r', name: 'Root'), (id: id, name: name)],
);
SearchStatusRoot rootInput(String path) => (
  id: 'r',
  name: 'Root',
  localPath: path,
  remoteRootId: 'r',
  excluded: <String>[],
  running: false,
  progressPath: null,
  progressComplete: null,
  errors: <String>{},
  conflicts: const PreparedConflictPaths({}, {}),
);

void main() {
  test(
    'production dispatches ordered bounded filesystem batches off caller',
    () async {
      final sizes = <int>[];
      final ids = <String>[];
      final result = await inspectSearchStatuses(
        snapshot: {
          for (var i = 0; i < 257; i++)
            '$i': SearchEntry(
              RemoteFile('$i', null, 'sealed', false, 0, true, 1, null),
              '$i',
            ),
        },
        folders: [],
        cancelled: () => false,
        groupNames: (_) async => {for (var i = 0; i < 257; i++) '$i'},
        inspectAncestries: (nodes, safe, requests, consume) =>
            inspectSearchStatusAncestries(nodes, safe, requests, (batch) async {
              sizes.add(batch.length);
              ids.addAll(batch.map((e) => e.id));
              await consume(WorkerOnlyBatch(batch));
            }),
      );
      expect(sizes, [128, 128, 1]);
      expect(result.keys, ids);
      expect(result.values.every((s) => s == SearchStatus.notCovered), isTrue);
    },
  );

  test(
    'worker freshly rechecks confined files, links, traversal and types',
    () async {
      final temporary = await Directory.systemTemp.createTemp('search-fs-');
      final root = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/file').writeAsString('local');
      await Directory('${root.path}/dir').create();
      if (!Platform.isWindows) {
        await Link('${root.path}/link').create('${root.path}/file');
      }
      final statuses = <String, SearchStatus>{};
      Future<void> inspect() => inspectSearchStatusFilesystem(
        [rootInput(root.path)],
        (send) async {
          final result = await send(
            WorkerOnlyBatch([
              item('file', 'file'),
              item('dir', 'dir', dir: true),
              item('missing', 'missing'),
              if (!Platform.isWindows) item('link', 'link'),
              item('traversal', '..'),
              item('wrong', 'dir'),
              (id: 'unsafe', isDir: false, ancestry: null),
            ]),
          );
          statuses.addAll({for (final value in result) value.id: value.status});
        },
      );
      await inspect();
      expect(statuses, {
        'file': SearchStatus.local,
        'dir': SearchStatus.local,
        'missing': SearchStatus.cloudOnly,
        if (!Platform.isWindows) 'link': SearchStatus.error,
        'traversal': SearchStatus.unknown,
        'wrong': SearchStatus.error,
        'unsafe': SearchStatus.unknown,
      });
      await File('${root.path}/file').delete();
      await inspect();
      expect(statuses['file'], SearchStatus.cloudOnly);
      if (!Platform.isWindows) {
        final linked = '${root.path}/root-link';
        await Link(linked).create(root.path);
        await inspectSearchStatusFilesystem([rootInput(linked)], (send) async {
          expect(
            (await send([item('file', 'file')])).single.status,
            SearchStatus.error,
          );
        });
      }
    },
  );

  for (final failure in [false, true]) {
    test(
      'worker finalization is awaited on producer failure=$failure',
      () async {
        final finalized = Completer<void>();
        final release = Completer<void>();
        var done = false;
        Future<void> observed(
          List<SearchStatusRoot> roots,
          SendPort ready,
        ) async {
          await runSearchStatusFilesystemWorker(roots, ready);
          finalized.complete();
          await release.future;
        }

        final future = inspectSearchStatusFilesystem([], (send) async {
          expect(
            (await send(WorkerOnlyBatch([item('a', 'a')]))).single.status,
            SearchStatus.notCovered,
          );
          if (failure) throw StateError('private diagnostic');
        }, worker: observed);
        final checked =
            (failure
                    ? expectLater(future, throwsA(isA<SearchUnavailable>()))
                    : future)
                .whenComplete(() => done = true);
        await finalized.future;
        expect(done, isFalse);
        release.complete();
        await checked;
      },
    );
  }

  test('invalid filesystem batches fail closed and drain', () async {
    for (final batch in <List<SearchStatusAncestry>>[
      [],
      [for (var i = 0; i < 129; i++) item('$i', '$i')],
    ]) {
      var finalized = false;
      await expectLater(
        inspectSearchStatusFilesystem(
          [],
          (send) async {
            await send(batch);
          },
          worker: (roots, ready) async {
            try {
              await runSearchStatusFilesystemWorker(roots, ready);
            } finally {
              finalized = true;
            }
          },
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      expect(finalized, isTrue);
    }
  });

  test('failed filesystem producer retains the prior complete index', () async {
    final search = AccountSearch(
      operations: SessionOperations(),
      handle: 1,
      list: (_) async => [
        RemoteFile('a', null, 'sealed', false, 0, true, 1, null),
      ],
      decrypt: (_) => 'a',
      authorize: () {},
    );
    addTearDown(search.dispose);
    await search.rebuild();
    final previous = search.snapshotRevision;
    await expectLater(
      search.rebuild(
        inspectStatuses: (snapshot, cancelled) => inspectSearchStatuses(
          snapshot: snapshot,
          folders: [],
          cancelled: cancelled,
          groupNames: (_) async => {'a'},
          inspectFilesystem: (roots, produce) =>
              inspectSearchStatusFilesystem(roots, (send) async {
                await produce(send);
                throw StateError('private diagnostic must not escape');
              }),
        ),
      ),
      throwsA(isA<SearchUnavailable>()),
    );
    expect(search.count, 1);
    expect(search.snapshotRevision, previous);
  });

  test(
    'session close drains suspended filesystem work and retains old snapshot',
    () async {
      final operations = SessionOperations();
      final entered = Completer<void>();
      final release = Completer<void>();
      final search = AccountSearch(
        handle: 1,
        operations: operations,
        list: (_) async => [
          RemoteFile('a', null, 'sealed', false, 0, true, 1, null),
        ],
        decrypt: (_) => 'a',
        authorize: () {},
      );
      addTearDown(search.dispose);
      await search.rebuild();
      final previous = search.snapshotRevision;
      final rebuilding = expectLater(
        search.rebuild(
          inspectStatuses: (snapshot, cancelled) => inspectSearchStatuses(
            snapshot: snapshot,
            folders: [],
            cancelled: cancelled,
            groupNames: (_) async => {'a'},
            inspectFilesystem: (roots, produce) =>
                inspectSearchStatusFilesystem(
                  roots,
                  produce,
                  worker: (inputs, ready) async {
                    await runSearchStatusFilesystemWorker(inputs, ready);
                    entered.complete();
                    await release.future;
                  },
                ),
          ),
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      await entered.future.timeout(const Duration(seconds: 10));
      search.close();
      var drained = false;
      final draining = operations.drain(1).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      release.complete();
      await rebuilding;
      await draining;
      expect(drained, isTrue);
      expect(search.snapshotRevision, previous);
    },
  );
}
