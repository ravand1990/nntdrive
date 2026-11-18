import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/search_status.dart';
import 'package:nntdrive/search_status_errors.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';

class WorkerOnlyPaths extends ListBase<SearchStatusErrorPath> {
  WorkerOnlyPaths(this.values) : caller = Isolate.current.controlPort;
  final List<SearchStatusErrorPath> values;
  final SendPort caller;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('resize');
  @override
  SearchStatusErrorPath operator [](int index) {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Error indexing ran on caller isolate');
    }
    return values[index];
  }

  @override
  void operator []=(int index, SearchStatusErrorPath value) =>
      throw UnsupportedError('write');
}

SyncFolderConfig folder(String id, List<dynamic> paths) => SyncFolderConfig(
  id: id,
  name: id,
  localPath: '.',
  remoteRootId: id,
  lastReport: {
    'item_errors': [
      {'operation': 'move', 'code': 'io', 'paths': paths},
    ],
  },
);

void main() {
  test(
    'error indexing reads paths off caller isolate and returns immutable sets',
    () async {
      final result = await indexSearchStatusErrors(
        3,
        Stream.fromIterable([
          WorkerOnlyPaths([(root: 0, path: 'a'), (root: 1, path: 'a')]),
          WorkerOnlyPaths([(root: 0, path: 'a'), (root: 0, path: 'dir/a')]),
        ]),
      );
      expect(result, [
        {'a', 'dir/a'},
        {'a'},
        <String>{},
      ]);
      expect(result[0].contains('prefix/a'), isFalse);
      expect(() => result[0].add('b'), throwsUnsupportedError);
      expect(() => result.add({}), throwsUnsupportedError);
    },
  );

  test(
    'production status wiring sends ordered bounded path batches to worker',
    () async {
      final sizes = <int>[];
      final sent = <SearchStatusErrorPath>[];
      List<Set<String>>? indexed;
      await inspectSearchStatuses(
        snapshot: {},
        folders: [
          folder('a', [for (var i = 0; i < 257; i++) 'path-$i']),
          folder('b', ['other']),
          folder('empty', []),
        ],
        cancelled: () => false,
        indexErrors: (count, batches) async {
          indexed = await indexSearchStatusErrors(
            count,
            batches.map((batch) {
              sizes.add(batch.length);
              sent.addAll(batch);
              // Only the worker may read this replacement, not a hidden fallback.
              return WorkerOnlyPaths(batch);
            }),
          );
          return indexed!;
        },
      );
      expect(sizes, [128, 128, 2]);
      expect(sent, [
        for (var i = 0; i < 257; i++) (root: 0, path: 'path-$i'),
        (root: 1, path: 'other'),
      ]);
      expect(indexed![0].length, 257);
      expect(indexed![1], {'other'});
      expect(indexed![2], isEmpty);
    },
  );

  for (final fail in [false, true]) {
    test(
      'producer finish/error awaits worker cleanup (failure: $fail)',
      () async {
        final finalized = Completer<void>();
        final release = Completer<void>();
        var completed = false;
        Future<List<Set<String>>> observed(int count, SendPort ready) async {
          final result = await runSearchStatusErrorWorker(count, ready);
          finalized.complete(); // Real port loop exited and final sets built.
          await release.future;
          return result;
        }

        Stream<List<SearchStatusErrorPath>> batches() async* {
          yield [(root: 0, path: 'a')];
          if (fail) throw StateError('private producer diagnostics');
        }

        final future = indexSearchStatusErrors(1, batches(), worker: observed);
        final assertion = fail
            ? expectLater(future, throwsA(isA<SearchUnavailable>()))
            : future.then(
                (value) => expect(value, [
                  {'a'},
                ]),
              );
        final done = assertion.whenComplete(() => completed = true);
        await finalized.future.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(Duration.zero);
        expect(completed, isFalse);
        release.complete();
        await done;
        // A failed producer cannot leave a background worker poisoning later work.
        expect(await indexSearchStatusErrors(1, const Stream.empty()), [
          <String>{},
        ]);
      },
    );
  }

  test(
    'status error worker remains in session drain and rejects close publication',
    () async {
      final operations = SessionOperations();
      final index = AccountSearch(
        handle: 1,
        operations: operations,
        list: (_) async => [
          RemoteFile('f', null, 'File', false, 0, true, 1, null),
        ],
        decrypt: (file) => file.nameEnc,
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      final revision = index.snapshotRevision;
      Stream<List<SearchStatusErrorPath>> failing(
        Stream<List<SearchStatusErrorPath>> batches,
      ) async* {
        await for (final batch in batches) {
          yield batch; // Real worker acknowledgement precedes producer failure.
          throw StateError('private report failure');
        }
      }

      await expectLater(
        index.rebuild(
          inspectStatuses: (snapshot, cancelled) => inspectSearchStatuses(
            snapshot: snapshot,
            folders: [
              folder('a', ['path']),
            ],
            cancelled: cancelled,
            indexErrors: (count, batches) =>
                indexSearchStatusErrors(count, failing(batches)),
          ),
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      expect(index.snapshotRevision, revision);
      expect(index.count, 1);
      final acknowledged = Completer<void>();
      final release = Completer<void>();
      Stream<List<SearchStatusErrorPath>> suspended(
        Stream<List<SearchStatusErrorPath>> batches,
      ) async* {
        await for (final batch in batches) {
          yield batch;
          acknowledged.complete();
          await release.future;
        }
      }

      final building = expectLater(
        index.rebuild(
          inspectStatuses: (snapshot, cancelled) => inspectSearchStatuses(
            snapshot: snapshot,
            folders: [
              folder('a', [for (var i = 0; i < 257; i++) 'path-$i']),
            ],
            cancelled: cancelled,
            indexErrors: (count, batches) =>
                indexSearchStatusErrors(count, suspended(batches)),
          ),
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      await acknowledged.future.timeout(const Duration(seconds: 10));
      index.close();
      var drained = false;
      final drain = operations.drain(1).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      release.complete();
      await building;
      await drain;
      expect(drained, isTrue);
      expect(index.snapshotRevision, revision);
      expect(index.count, 0);
    },
  );

  test('invalid batches fail closed and finish worker', () async {
    for (final batch in <List<SearchStatusErrorPath>>[
      [],
      [(root: 1, path: 'a')],
      [for (var i = 0; i < 129; i++) (root: 0, path: '$i')],
    ]) {
      await expectLater(
        indexSearchStatusErrors(1, Stream.value(batch)),
        throwsA(isA<SearchUnavailable>()),
      );
    }
  });
}
