import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/session_operations.dart';

RemoteFile row(
  String id,
  String? parent, {
  bool dir = false,
  bool favorite = false,
  int size = 20,
  DateTime? modified,
}) =>
    RemoteFile(
      id,
      parent,
      'opaque',
      dir,
      size,
      favorite,
      1,
      null,
      updatedAt: modified,
    );

// No injected runner: observe where the production scanner reads its rows.
// Even delaying a synchronous UI scan would fail this identity check.
class IsolateCheckedEntry extends SearchEntry {
  IsolateCheckedEntry(super.file, super.name)
      : sourceIsolate = Isolate.current.hashCode;
  final int sourceIsolate;

  @override
  String get foldedName {
    if (Isolate.current.hashCode == sourceIsolate) {
      throw StateError('Query scanned on caller isolate');
    }
    return name.toLowerCase();
  }
}

void main() {
  test('production scanner reads entries on a different isolate', () async {
    final entry = IsolateCheckedEntry(row('a', null), 'Match');
    expect(
        await runSearchQuery(
            {'a': entry}, const SearchFilter(text: 'match'), 200),
        ['a']);
  });

  test(
      'query workers serialize, skip superseded work and discard old snapshots',
      () async {
    for (final replaceSnapshot in [false, true]) {
      final operations = SessionOperations();
      final entered = Completer<void>();
      final release = Completer<void>();
      var calls = 0;
      var generation = 'old';
      final index = AccountSearch(
        handle: 30,
        operations: operations,
        list: (_) async => [row('a', null)],
        decrypt: (_) => generation,
        authorize: () {},
        queryWorker: (snapshot, filter, limit) async {
          calls++;
          if (calls == 1) {
            entered.complete();
            await release.future;
          }
          return runSearchQuery(snapshot, filter, limit);
        },
      );
      addTearDown(index.dispose);
      await index.rebuild();
      final first = index.search(const SearchFilter());
      await entered.future;
      final second = index.search(const SearchFilter());
      final third = index.search(const SearchFilter());
      generation = 'new';
      if (replaceSnapshot) await index.rebuild();
      final latest = index.search(const SearchFilter());
      release.complete();
      expect(await first, isEmpty);
      expect(await second, isEmpty);
      expect(await third, isEmpty);
      expect((await latest).single.name, replaceSnapshot ? 'new' : 'old');
      expect(calls, 2);
    }
  });

  test(
      'query close drains running worker and queued admissions before revocation',
      () async {
    final operations = SessionOperations();
    final entered = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    var revoked = false;
    final index = AccountSearch(
      handle: 31,
      operations: operations,
      list: (_) async => [row('a', null)],
      decrypt: (_) => 'private',
      authorize: () {
        expect(revoked, isFalse);
      },
      queryWorker: (snapshot, filter, limit) async {
        calls++;
        entered.complete();
        await release.future;
        expect(revoked, isFalse);
        return runSearchQuery(snapshot, filter, limit);
      },
    );
    addTearDown(index.dispose);
    await index.rebuild();
    final first = expectLater(
        index.search(const SearchFilter()), throwsA(isA<SearchUnavailable>()));
    await entered.future;
    final queued = expectLater(
        index.search(const SearchFilter()), throwsA(isA<SearchUnavailable>()));
    index.close();
    final drain = operations.drain(31).then((_) => revoked = true);
    await Future<void>.delayed(Duration.zero);
    expect(revoked, isFalse);
    await expectLater(
        index.search(const SearchFilter()), throwsA(isA<SearchUnavailable>()));
    release.complete();
    await Future.wait([first, queued, drain]);
    expect(revoked, isTrue);
    expect(calls, 1);
    expect(index.count, 0);
  });

  test('snapshot publication alone invalidates a running query', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final index = AccountSearch(
      handle: 34,
      operations: SessionOperations(),
      list: (_) async => [row('a', null)],
      decrypt: (_) => 'private',
      authorize: () {},
      queryWorker: (snapshot, filter, limit) async {
        entered.complete();
        await release.future;
        return runSearchQuery(snapshot, filter, limit);
      },
    );
    addTearDown(index.dispose);
    await index.rebuild();
    final pending = index.search(const SearchFilter());
    await entered.future;
    await index.rebuild();
    release.complete();
    expect(await pending, isEmpty);
  });

  test('worker failure is redacted, releases queue and preserves snapshot',
      () async {
    var fail = true;
    final index = AccountSearch(
      handle: 32,
      operations: SessionOperations(),
      list: (_) async => [row('a', null)],
      decrypt: (_) => 'private',
      authorize: () {},
      queryWorker: (snapshot, filter, limit) {
        if (fail) throw StateError('private query/token');
        return runSearchQuery(snapshot, filter, limit);
      },
    );
    addTearDown(index.dispose);
    await index.rebuild();
    await expectLater(
        index.search(const SearchFilter()),
        throwsA(predicate((Object e) =>
            e is SearchUnavailable && !e.toString().contains('private'))));
    fail = false;
    expect((await index.search(const SearchFilter())).single.name, 'private');
  });

  test('top-k tie order and filter boundaries remain exact', () async {
    final date = DateTime.utc(2026);
    final index = AccountSearch(
      handle: 33,
      operations: SessionOperations(),
      list: (parent) async => parent != null
          ? []
          : [
              row('z', null, modified: date, favorite: true),
              row('a', null, modified: date, favorite: true),
              row('d', null, dir: true, modified: date, favorite: true),
              row('missing', null, favorite: true),
            ],
      decrypt: (_) => 'Match.PDF',
      authorize: () {},
    );
    addTearDown(index.dispose);
    await index.rebuild();
    final f = SearchFilter(
        text: ' MATCH.PDF ',
        extension: '.PDF',
        minSize: 20,
        maxSize: 20,
        favoritesOnly: true,
        modifiedAfter: date,
        modifiedBefore: date.add(const Duration(seconds: 1)));
    expect((await index.search(f)).map((e) => e.file.id), ['a', 'z']);
    expect((await index.search(f, limit: 0)).single.file.id, 'a');
    expect(await index.search(SearchFilter(modifiedBefore: date)), isEmpty);
  });

  test('async batches are bounded, sequential and atomically published',
      () async {
    final data = List.generate(257, (i) => row('$i', null));
    final sizes = <int>[];
    var active = 0;
    var fail = false;
    late AccountSearch index;
    index = AccountSearch(
      handle: 20,
      operations: SessionOperations(),
      list: (_) async => data,
      decrypt: (_) => throw StateError('sync path used'),
      decryptBatch: (files) async {
        sizes.add(files.length);
        expect(++active, 1);
        // No partial snapshot is visible across any batch boundary.
        expect(index.count, index.ready ? 257 : 0);
        await Future<void>.delayed(Duration.zero);
        active--;
        if (fail && sizes.length == 2) throw StateError('private name/token');
        return files.map((f) => 'name-${f.id}').toList();
      },
      authorize: () {},
    );
    addTearDown(index.dispose);
    await index.rebuild();
    expect(sizes, [128, 128, 1]);
    expect(index.count, 257);
    sizes.clear();
    fail = true;
    await expectLater(
        index.rebuild(),
        throwsA(predicate((Object e) =>
            e is SearchUnavailable && !e.toString().contains('private'))));
    expect(index.ready, isTrue);
    expect(index.failed, isTrue);
    expect(index.count, 257);
    expect(
        (await index.search(const SearchFilter(text: 'name-256'))).single.name,
        'name-256');
  });

  test('close drains suspended async batch and rejects late publication',
      () async {
    final entered = Completer<void>();
    final result = Completer<List<String>>();
    final operations = SessionOperations();
    var calls = 0;
    final index = AccountSearch(
      handle: 21,
      operations: operations,
      list: (_) async => List.generate(129, (i) => row('$i', null)),
      decrypt: (_) => throw StateError('sync path used'),
      decryptBatch: (_) {
        calls++;
        entered.complete();
        return result.future;
      },
      authorize: () {},
    );
    addTearDown(index.dispose);
    final rejected =
        expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
    await entered.future.timeout(const Duration(seconds: 5));
    index.close();
    var drained = false;
    final drain = operations.drain(21).then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    result.complete(List.filled(128, 'secret'));
    await rejected;
    await drain;
    expect(calls, 1);
    expect(index.count, 0);
    expect(index.ready, isFalse);
    await expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
  });

  test('wrong batch result length cannot publish', () async {
    final index = AccountSearch(
      handle: 22,
      operations: SessionOperations(),
      list: (_) async => [row('a', null)],
      decrypt: (_) => throw StateError('sync path used'),
      decryptBatch: (_) async => [],
      authorize: () {},
    );
    addTearDown(index.dispose);
    await expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
    expect(index.count, 0);
    expect(index.ready, isFalse);
  });

  test(
    'walks nested and empty folders; ranks names and combines real metadata',
    () async {
      final calls = <String?>[];
      final tree = <String?, List<RemoteFile>>{
        null: [
          row('folder', null, dir: true),
          row('prefix', null),
          row('empty', null, dir: true),
        ],
        'folder': [row('nested', 'folder', dir: true)],
        'nested': [
          row(
            'exact',
            'nested',
            favorite: true,
            size: 42,
            modified: DateTime.utc(2026, 1, 2),
          ),
          row('substring', 'nested'),
        ],
        'empty': [],
      };
      final names = {
        'folder': 'Private',
        'prefix': 'Report.pdf backup',
        'empty': 'Empty',
        'nested': 'Archive',
        'exact': 'Report.pdf',
        'substring': 'old-report.pdf',
      };
      final index = AccountSearch(
        handle: 1,
        operations: SessionOperations(),
        list: (p) async {
          calls.add(p);
          return tree[p] ?? [];
        },
        decrypt: (f) => names[f.id]!,
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      expect(calls, [null, 'folder', 'empty', 'nested']);
      final ranked = await index.search(const SearchFilter(text: 'report.pdf'));
      expect(ranked.map((e) => e.file.id), ['exact', 'prefix', 'substring']);
      expect(index.folderPath(ranked.first), '/Private/Archive');
      expect(index.ancestors(ranked.first).map((e) => e.file.id), [
        'folder',
        'nested',
      ]);
      final result = await index.search(
        SearchFilter(
          text: 'REPORT',
          kind: SearchKind.file,
          extension: '.PDF',
          minSize: 40,
          maxSize: 50,
          favoritesOnly: true,
          modifiedAfter: DateTime.utc(2026),
          modifiedBefore: DateTime.utc(2026, 2),
        ),
      );
      expect(result.single.file.id, 'exact');
      expect(
        await index.search(SearchFilter(modifiedAfter: DateTime.utc(2027))),
        isEmpty,
      );
      expect(
        (await index.search(const SearchFilter(kind: SearchKind.folder)))
            .length,
        3,
      );
      expect(
        (await index.search(const SearchFilter(text: 'report pdf'))).length,
        3,
      );
    },
  );

  test(
      'offline snapshot, recent and saved filters never issue query requests; close clears account',
      () async {
    var offline = false;
    var calls = 0;
    final index = AccountSearch(
      handle: 1,
      operations: SessionOperations(),
      list: (_) async {
        calls++;
        if (offline) throw Exception('private diagnostic');
        return [row('a', null)];
      },
      decrypt: (_) => 'Secret.txt',
      authorize: () {},
    );
    addTearDown(index.dispose);
    await index.rebuild();
    offline = true;
    const filter = SearchFilter(text: 'secret', minSize: 10);
    index.remember(filter);
    index.remember(filter, save: true);
    await expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
    expect((await index.search(filter)).single.name, 'Secret.txt');
    expect(calls, 2);
    expect(index.failed, isTrue);
    expect(index.recent.single, filter);
    expect(index.saved.single, filter);
    index.close();
    expect(index.count, 0);
    expect(index.ready, isFalse);
    expect(index.recent, isEmpty);
    expect(index.saved, isEmpty);
    await expectLater(index.search(filter), throwsA(isA<SearchUnavailable>()));
    await expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
    expect(calls, 2);
    final other = AccountSearch(
      handle: 2,
      operations: SessionOperations(),
      list: (_) async => [],
      decrypt: (_) => '',
      authorize: () {},
    );
    addTearDown(other.dispose);
    await other.rebuild();
    expect(await other.search(filter), isEmpty);
    expect(other.saved, isEmpty);
  });

  test(
      'close before delayed listing prevents late decryption; drain waits for workflow',
      () async {
    final pending = Completer<List<RemoteFile>>();
    final entered = Completer<void>();
    var opens = 0;
    final operations = SessionOperations();
    final index = AccountSearch(
      handle: 3,
      operations: operations,
      list: (_) {
        entered.complete();
        return pending.future;
      },
      decrypt: (_) {
        opens++;
        return 'secret';
      },
      authorize: () {},
    );
    addTearDown(index.dispose);
    final build = index.rebuild();
    final rejected = expectLater(build, throwsA(isA<SearchUnavailable>()));
    await entered.future;
    index.close();
    var drained = false;
    final drain = operations.drain(3).then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    pending.complete([row('late', null)]);
    await rejected;
    await drain;
    expect(opens, 0);
    expect(index.count, 0);
    expect(index.ready, isFalse);
  });

  test(
    'locked admission fails before HTTP, errors exclude upstream diagnostics',
    () async {
      var requests = 0;
      final index = AccountSearch(
        handle: 4,
        operations: SessionOperations(),
        list: (_) async {
          requests++;
          return [];
        },
        decrypt: (_) => '',
        authorize: () => throw StateError('sensitive name/token'),
      );
      addTearDown(index.dispose);
      await expectLater(
        index.rebuild(),
        throwsA(
          predicate(
            (Object e) =>
                e is SearchUnavailable && !e.toString().contains('sensitive'),
          ),
        ),
      );
      await expectLater(
        index.search(const SearchFilter()),
        throwsA(isA<SearchUnavailable>()),
      );
      expect(requests, 0);
    },
  );

  test(
    'unreadable or malformed nested tree never publishes a partial snapshot',
    () async {
      var bad = false;
      final index = AccountSearch(
        handle: 5,
        operations: SessionOperations(),
        list: (parent) async => parent == null
            ? [row('d', null, dir: true)]
            : [row('x', bad ? null : 'd')],
        decrypt: (f) => f.id,
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      bad = true;
      await expectLater(index.rebuild(), throwsA(isA<SearchUnavailable>()));
      expect(index.count, 2);
      expect(
        (await index.search(const SearchFilter(text: 'x')))
            .single
            .file
            .parentId,
        'd',
      );
    },
  );

  test(
    '100k bounded results yield and session close cancels an active scan',
    () async {
      final data = List.generate(100000, (i) => row('$i', null));
      final index = AccountSearch(
        handle: 6,
        operations: SessionOperations(),
        list: (_) async => data,
        decrypt: (f) => 'file-${f.id}.txt',
        authorize: () {},
      );
      addTearDown(index.dispose);
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      addTearDown(timer.cancel);
      await index.rebuild();
      expect(index.count, 100000);
      expect(ticks, greaterThan(0));
      ticks = 0;
      expect(
        (await index.search(const SearchFilter(text: 'file'))).length,
        200,
      );
      expect(ticks, greaterThan(0)); // query worker permits real timer events
      final pending = index.search(const SearchFilter(text: 'file'));
      index.close();
      await expectLater(pending, throwsA(isA<SearchUnavailable>()));
      expect(index.count, 0);
    },
  );

  test(
    '10k warm query latency target, top-k instead of sorting every match',
    () async {
      final data = List.generate(10000, (i) => row('$i', null));
      final index = AccountSearch(
        handle: 7,
        operations: SessionOperations(),
        list: (_) async => data,
        decrypt: (f) => 'report-${f.id}.pdf',
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      final samples = <int>[];
      for (var i = 0; i < 20; i++) {
        final watch = Stopwatch()..start();
        expect(
          (await index.search(const SearchFilter(text: 'report'))).length,
          200,
        );
        samples.add(watch.elapsedMicroseconds);
      }
      samples.sort();
      final p95 = samples[18];
      // This is isolated test-run timing, not installed-device acceptance.
      // ignore: avoid_print
      print('10k warm search p95: $p95 us (20 queries)');
      expect(p95, lessThan(150000));
    },
  );
}
