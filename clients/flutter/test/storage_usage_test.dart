import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/storage_usage.dart';

RemoteFile file(String id, String? parent, int size, {bool dir = false}) =>
    RemoteFile(id, parent, 'sealed-$id', dir, size, false, 1, null);
SearchEntry entry(
  String id,
  String? parent,
  String name,
  int size, {
  bool dir = false,
}) => SearchEntry(file(id, parent, size, dir: dir), name);

class WorkerEntry extends SearchEntry {
  WorkerEntry()
    : caller = Isolate.current.hashCode,
      super(file('guard', null, 7), 'guard.txt');
  final int caller;
  @override
  String get name {
    if (caller == Isolate.current.hashCode) throw StateError('caller scan');
    return 'guard.txt';
  }
}

void main() {
  test(
    'empty, group identity, deterministic ties and overflow rejection',
    () async {
      final empty = await runStorageUsage({});
      expect((empty.files, empty.bytes), (0, 0));
      expect(empty.folders, isEmpty);
      final usage = await runStorageUsage({
        'a': entry('a', null, 'Same', 0, dir: true),
        'b': entry('b', null, 'Same', 0, dir: true),
        'f': entry('f', 'a', 'first', 2),
        'g': entry('g', 'b', 'second', 2),
      });
      expect(usage.folders.length, 2);
      expect(usage.folders.map((b) => b.files), [1, 1]);
      expect(usage.largest.map((f) => f.path), ['Same/first', 'Same/second']);
      await expectLater(
        runStorageUsage({
          'a': entry('a', null, 'huge', 0x7fffffffffffffff),
          'b': entry('b', null, 'overflow', 1),
        }),
        throwsA(isA<SearchUnavailable>()),
      );
      await expectLater(
        runStorageUsage({
          for (var i = 0; i < 100001; i++) '$i': entry('$i', null, 'x', 0),
        }),
        throwsA(isA<SearchUnavailable>()),
      );
    },
  );

  test(
    'replacement during worker and worker diagnostics are rejected safely',
    () async {
      final index = AccountSearch(
        handle: 2,
        operations: SessionOperations(),
        list: (_) async => [file('f', null, 1)],
        decrypt: (_) => 'x',
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = index.readSnapshot((snapshot) async {
        entered.complete();
        await release.future;
        return runStorageUsage(snapshot);
      });
      await entered.future;
      await index.rebuild();
      final rejected = expectLater(pending, throwsA(isA<SearchUnavailable>()));
      release.complete();
      await rejected;
      await expectLater(
        index.readSnapshot<StorageUsage>(
          (_) async => throw StateError('private filename/token'),
        ),
        throwsA(
          predicate(
            (Object error) =>
                error is SearchUnavailable &&
                !error.toString().contains('private'),
          ),
        ),
      );
    },
  );

  test(
    'exact live totals, nested top-level buckets, extensions and empty files',
    () async {
      final result = await runStorageUsage({
        'a': entry('a', null, 'Photos', 999, dir: true),
        'b': entry('b', 'a', 'Nested', 0, dir: true),
        'c': entry('c', 'b', 'image.JPG', 100),
        'd': entry('d', null, 'readme', 5),
        'e': entry('e', 'a', '.hidden', 0),
        'f': entry('f', null, 'empty.txt', 0),
        'g': entry('g', null, 'Empty folder', 0, dir: true),
      });
      expect(result.bytes, 105);
      expect(result.files, 4);
      expect(result.folders.map((b) => (b.label, b.bytes, b.files)), [
        ('Photos', 100, 2),
        ('Files at account root', 5, 2),
        ('Empty folder', 0, 0),
      ]);
      expect(result.types.map((b) => (b.label, b.bytes, b.files)), [
        ('.jpg', 100, 1),
        ('No extension', 5, 2),
        ('.txt', 0, 1),
      ]);
      expect(result.largest.first.path, 'Photos/Nested/image.JPG');
      expect(result.largest.map((f) => f.bytes), [100, 5, 0, 0]);
      expect(() => result.largest.clear(), throwsUnsupportedError);
    },
  );

  test(
    'bounded output retains exact totals and deterministic top 20',
    () async {
      final result = await runStorageUsage({
        for (var i = 0; i < 100000; i++) '$i': entry('$i', null, 'file.$i', i),
      });
      expect(result.files, 100000);
      expect(result.bytes, 4999950000);
      expect(result.largest.length, 20);
      expect(result.largest.first.bytes, 99999);
      expect(result.largest.last.bytes, 99980);
      expect(result.types.length, 21); // 20 named buckets + exact remainder.
      expect(result.types.fold<int>(0, (sum, b) => sum + b.files), 100000);
      expect(
        result.types.fold<int>(0, (sum, b) => sum + b.bytes),
        result.bytes,
      );
    },
  );

  test('production aggregation reads entries off the caller isolate', () async {
    final result = await runStorageUsage({'guard': WorkerEntry()});
    expect(result.bytes, 7);
  });

  test('aggregation yields a real event turn even for one file', () async {
    var yielded = false;
    Timer.run(() => yielded = true);
    await runStorageUsage({'x': entry('x', null, 'x', 1)});
    expect(yielded, isTrue);
  });

  test(
    'rejects invalid sizes and broken ancestry rather than inventing totals',
    () async {
      for (final snapshot in [
        {'a': entry('a', null, 'bad', -1)},
        {'a': entry('a', 'missing', 'bad', 1)},
        {'a': entry('a', 'a', 'cycle', 0, dir: true)},
      ]) {
        await expectLater(
          runStorageUsage(snapshot),
          throwsA(isA<SearchUnavailable>()),
        );
      }
    },
  );

  test(
    'owned snapshot refresh changes totals and failed refresh retains complete data',
    () async {
      var rows = [file('a', null, 4)];
      var offline = false;
      final ops = SessionOperations();
      final index = AccountSearch(
        handle: 1,
        operations: ops,
        list: (_) async {
          if (offline) throw StateError('private diagnostic');
          return rows;
        },
        decrypt: (f) => '${f.id}.txt',
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      expect((await index.readSnapshot(runStorageUsage)).bytes, 4);
      rows = [file('b', null, 9), file('c', null, 2)];
      await index.rebuild();
      expect((await index.readSnapshot(runStorageUsage)).bytes, 11);
      offline = true;
      await expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
      expect((await index.readSnapshot(runStorageUsage)).files, 2);
      final entered = Completer<void>();
      final finish = Completer<void>();
      final pending = index.readSnapshot((snapshot) async {
        entered.complete();
        await finish.future;
        return runStorageUsage(snapshot);
      });
      await entered.future;
      index.close();
      var drained = false;
      final drain = ops.drain(1).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      final rejection = expectLater(pending, throwsA(isA<SearchUnavailable>()));
      finish.complete();
      await rejection;
      await drain;
      await expectLater(
        index.readSnapshot(runStorageUsage),
        throwsA(isA<SearchUnavailable>()),
      );
    },
  );
}
