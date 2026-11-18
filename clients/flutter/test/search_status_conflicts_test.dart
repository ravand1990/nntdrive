import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/conflict_paths.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/search_status.dart';
import 'package:nntdrive/search_status_conflicts.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';

class WorkerOnlyConflicts extends ListBase<SearchStatusConflictPath> {
  WorkerOnlyConflicts(this.values) : caller = Isolate.current.controlPort;
  final List<SearchStatusConflictPath> values;
  final SendPort caller;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('resize');
  @override
  SearchStatusConflictPath operator [](int index) {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Conflict indexing ran on caller isolate');
    }
    return values[index];
  }

  @override
  void operator []=(int index, SearchStatusConflictPath value) =>
      throw UnsupportedError('write');
}

SyncFolderConfig folder(String id, List<String> paths) =>
    SyncFolderConfig(id: id, name: id, localPath: '.', remoteRootId: id)
      ..conflictFiles = paths;

void main() {
  test(
    'conflict indexing reads paths off caller isolate and returns immutable sets',
    () async {
      final result = await indexSearchStatusConflicts(
        3,
        Stream.fromIterable([
          WorkerOnlyConflicts([(root: 0, path: 'a'), (root: 1, path: 'a')]),
          WorkerOnlyConflicts([(root: 0, path: 'a'), (root: 0, path: 'dir/a')]),
        ]),
      );
      expect(result.map((index) => index.exact).toList(), [
        {'a', 'dir/a'},
        {'a'},
        <String>{},
      ]);
      expect(result[0].exact.contains('prefix/a'), isFalse);
      expect(() => result[0].exact.add('b'), throwsUnsupportedError);
      expect(() => result.clear(), throwsUnsupportedError);
    },
  );

  test(
    'production status wiring sends ordered bounded path batches to worker',
    () async {
      final sizes = <int>[];
      final sent = <SearchStatusConflictPath>[];
      List<PreparedConflictPaths>? indexed;
      await inspectSearchStatuses(
        snapshot: {},
        folders: [
          folder('a', [for (var i = 0; i < 257; i++) 'path-$i']),
          folder('b', ['other']),
          folder('empty', []),
        ],
        cancelled: () => false,
        indexConflicts: (count, batches) async {
          indexed = await indexSearchStatusConflicts(
            count,
            batches.map((batch) {
              sizes.add(batch.length);
              sent.addAll(batch);
              // Only the worker may read this replacement, not a hidden fallback.
              return WorkerOnlyConflicts(batch);
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
      expect(indexed![0].exact.length, 257);
      expect(indexed![1].exact, {'other'});
      expect(indexed![2].exact, isEmpty);
    },
  );

  for (final fail in [false, true]) {
    test(
      'producer finish/error awaits worker cleanup (failure: $fail)',
      () async {
        final finalized = Completer<void>();
        final release = Completer<void>();
        var completed = false;
        Future<List<PreparedConflictPaths>> observed(
          int count,
          SendPort ready,
        ) async {
          final result = await runSearchStatusConflictWorker(count, ready);
          finalized.complete(); // Real port loop exited and final sets built.
          await release.future;
          return result;
        }

        Stream<List<SearchStatusConflictPath>> batches() async* {
          yield [(root: 0, path: 'a')];
          if (fail) throw StateError('private producer diagnostics');
        }

        final future = indexSearchStatusConflicts(
          1,
          batches(),
          worker: observed,
        );
        final assertion = fail
            ? expectLater(future, throwsA(isA<SearchUnavailable>()))
            : future.then(
                (value) => expect(value.map((index) => index.exact).toList(), [
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
        expect(
          (await indexSearchStatusConflicts(
            1,
            const Stream.empty(),
          )).map((index) => index.exact).toList(),
          [<String>{}],
        );
      },
    );
  }

  test(
    'status conflict worker remains in session drain and rejects close publication',
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
      Stream<List<SearchStatusConflictPath>> failing(
        Stream<List<SearchStatusConflictPath>> batches,
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
            indexConflicts: (count, batches) =>
                indexSearchStatusConflicts(count, failing(batches)),
          ),
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      expect(index.snapshotRevision, revision);
      expect(index.count, 1);
      final acknowledged = Completer<void>();
      final release = Completer<void>();
      Stream<List<SearchStatusConflictPath>> suspended(
        Stream<List<SearchStatusConflictPath>> batches,
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
            indexConflicts: (count, batches) =>
                indexSearchStatusConflicts(count, suspended(batches)),
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
    for (final batch in <List<SearchStatusConflictPath>>[
      [],
      [(root: 1, path: 'a')],
      [for (var i = 0; i < 129; i++) (root: 0, path: '$i')],
    ]) {
      await expectLater(
        indexSearchStatusConflicts(1, Stream.value(batch)),
        throwsA(isA<SearchUnavailable>()),
      );
    }
  });
}
