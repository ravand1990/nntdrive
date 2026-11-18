import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/session_operations.dart';

RemoteFile file(String id) =>
    RemoteFile(id, null, 'opaque', false, 23, true, 1, 'revision');

// Sendable: publication may only construct status replacements off the caller.
class WorkerStatusEntry extends SearchEntry {
  WorkerStatusEntry(super.file, super.name) : caller = Isolate.current.hashCode;
  final int caller;

  @override
  SearchEntry withStatus(SearchStatus value) {
    if (Isolate.current.hashCode == caller) {
      throw StateError('Status publication ran on the caller');
    }
    return super.withStatus(value);
  }
}

void main() {
  test(
    'status projection preserves keys, metadata and all status semantics',
    () async {
      final snapshot = <String, SearchEntry>{
        for (final status in SearchStatus.values)
          status.name: SearchEntry(file('node-${status.name}'), 'MiXeD.txt'),
        'missing': SearchEntry(file('missing'), 'Missing'),
      };
      final result = await runSearchStatusPublication(snapshot, {
        for (final status in SearchStatus.values) status.name: status,
        'not-in-snapshot': SearchStatus.error,
      });
      expect(result.keys, snapshot.keys);
      for (final status in SearchStatus.values) {
        final entry = result[status.name]!;
        expect(
          entry.status,
          status == SearchStatus.all ? SearchStatus.unknown : status,
        );
        expect(entry.file.id, 'node-${status.name}');
        expect(entry.file.currentVersion, 'revision');
        expect(entry.file.size, 23);
        expect(entry.file.favorite, isTrue);
        expect(entry.name, 'MiXeD.txt');
        expect(entry.foldedName, 'mixed.txt');
        expect(snapshot[status.name]!.status, SearchStatus.unknown);
      }
      expect(result['missing']!.status, SearchStatus.unknown);
      expect(
        await runSearchStatusPublication({}, {'extra': SearchStatus.error}),
        isEmpty,
      );
    },
  );

  test('single-entry status publication yields a real event turn', () async {
    var eventRan = false;
    Timer.run(() => eventRan = true);
    await runSearchStatusPublication(
      {'a': SearchEntry(file('a'), 'Name')},
      {'a': SearchStatus.local},
    );
    expect(eventRan, isTrue);
  });

  test(
    'publication failure retains previous snapshot and retry replaces it',
    () async {
      var fail = false;
      var calls = 0;
      final index = AccountSearch(
        handle: 61,
        operations: SessionOperations(),
        list: (_) async => [file('a')],
        decrypt: (_) => 'Name',
        statusWorker: (entries, statuses) async {
          calls++;
          final result = await runSearchStatusPublication(entries, statuses);
          if (fail) throw StateError('private path/token');
          return result;
        },
        authorize: () {},
      );
      addTearDown(index.dispose);
      Future<void> build(SearchStatus status) =>
          index.rebuild(inspectStatuses: (_, _) async => {'a': status});
      await build(SearchStatus.local);
      fail = true;
      await expectLater(
        build(SearchStatus.error),
        throwsA(
          predicate(
            (Object e) =>
                e is SearchUnavailable && !e.toString().contains('private'),
          ),
        ),
      );
      expect(index.failed, isTrue);
      expect(index.snapshotRevision, 1);
      expect(
        (await index.search(const SearchFilter())).single.status,
        SearchStatus.local,
      );
      fail = false;
      await build(SearchStatus.error);
      expect(index.failed, isFalse);
      expect(index.snapshotRevision, 2);
      expect(
        (await index.search(const SearchFilter())).single.status,
        SearchStatus.error,
      );
      expect(calls, 3);
      await index.rebuild(); // No inspector means no status projection.
      expect(calls, 3);
      expect(
        (await index.search(const SearchFilter())).single.status,
        SearchStatus.unknown,
      );
    },
  );

  test(
    'close drains suspended final publication and rejects late output',
    () async {
      final operations = SessionOperations();
      final entered = Completer<void>();
      final release = Completer<void>();
      var hold = false;
      var calls = 0;
      final index = AccountSearch(
        handle: 62,
        operations: operations,
        list: (_) async => [file('a')],
        decrypt: (_) => 'Name',
        statusWorker: (entries, statuses) async {
          calls++;
          final result = await runSearchStatusPublication(entries, statuses);
          if (hold) {
            entered.complete();
            await release.future;
          }
          return result;
        },
        authorize: () {},
      );
      addTearDown(index.dispose);
      Future<void> build() => index.rebuild(
        inspectStatuses: (_, _) async => {'a': SearchStatus.local},
      );
      await build();
      hold = true;
      final pending = build();
      final rejected = expectLater(pending, throwsA(isA<SearchUnavailable>()));
      await entered.future.timeout(const Duration(seconds: 5));
      expect(index.snapshotRevision, 1);
      expect(index.count, 1);
      expect(
        identical(pending, build()),
        isTrue,
      ); // Rebuild stays single-flight.
      index.close();
      var drained = false;
      final drain = operations.drain(62).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      await expectLater(build(), throwsA(isA<SearchUnavailable>()));
      release.complete();
      await Future.wait([rejected, drain]);
      expect(drained, isTrue);
      expect(calls, 2);
      expect(index.count, 0);
      expect(index.snapshotRevision, 1);
      expect(index.ready, isFalse);
    },
  );

  test(
    'final authorization still rejects a completed status projection',
    () async {
      var locked = false;
      final index = AccountSearch(
        handle: 63,
        operations: SessionOperations(),
        list: (_) async => [file('a')],
        decrypt: (_) => 'Name',
        statusWorker: (entries, statuses) async {
          final result = await runSearchStatusPublication(entries, statuses);
          locked = true;
          return result;
        },
        authorize: () {
          if (locked) throw StateError('locked');
        },
      );
      addTearDown(index.dispose);
      await expectLater(
        index.rebuild(
          inspectStatuses: (_, _) async => {'a': SearchStatus.local},
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      expect(index.closed, isTrue);
      expect(index.count, 0);
      expect(index.snapshotRevision, 0);
    },
  );

  test('production status publication replaces entries on a worker', () async {
    final index = AccountSearch(
      handle: 60,
      operations: SessionOperations(),
      list: (_) async => [file('a')],
      decrypt: (_) => 'MiXeD.txt',
      entryWorker: (files, names) async => {
        'a': WorkerStatusEntry(files.single, names.single!),
      },
      authorize: () {},
    );
    addTearDown(index.dispose);
    await index.rebuild(
      inspectStatuses: (_, _) async => {'a': SearchStatus.local},
    );
    final entry = (await index.search(
      const SearchFilter(status: SearchStatus.local, text: 'mixed'),
    )).single;
    expect(entry.name, 'MiXeD.txt');
    expect(entry.foldedName, 'mixed.txt');
    expect(entry.file.currentVersion, 'revision');
    expect(index.snapshotRevision, 1);
  });
}
