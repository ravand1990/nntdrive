import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/search_status.dart';
import 'package:nntdrive/search_status_ancestry.dart';
import 'package:nntdrive/session_operations.dart';

SearchEntry entry(String id, String? parent, {bool dir = false}) =>
    SearchEntry(RemoteFile(id, parent, id, dir, 0, true, 1, null), id);

class NoCallerParentLookup extends MapBase<String, SearchEntry> {
  NoCallerParentLookup(this.valuesMap) : caller = Isolate.current.controlPort;
  final Map<String, SearchEntry> valuesMap;
  final SendPort caller;
  @override
  Iterable<String> get keys => valuesMap.keys;
  @override
  Iterable<SearchEntry> get values => valuesMap.values;
  @override
  Iterable<MapEntry<String, SearchEntry>> get entries => valuesMap.entries;
  @override
  int get length => valuesMap.length;
  @override
  SearchEntry? operator [](Object? key) {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Ancestor lookup ran on caller');
    }
    return valuesMap[key];
  }

  @override
  void operator []=(String key, SearchEntry value) =>
      throw UnsupportedError('write');
  @override
  void clear() => throw UnsupportedError('clear');
  @override
  SearchEntry? remove(Object? key) => throw UnsupportedError('remove');
}

class WorkerOnlyNodes extends ListBase<SearchStatusNode> {
  WorkerOnlyNodes(this.nodes) : caller = Isolate.current.controlPort;
  final List<SearchStatusNode> nodes;
  final SendPort caller;
  @override
  int get length => nodes.length;
  @override
  set length(int value) => throw UnsupportedError('resize');
  @override
  SearchStatusNode operator [](int index) {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Ancestry worker ran on caller');
    }
    return nodes[index];
  }

  @override
  void operator []=(int index, SearchStatusNode value) =>
      throw UnsupportedError('write');
}

SearchStatusNode node(String id, String? parent, {bool dir = true}) =>
    (key: id, id: id, parent: parent, name: id, isDir: dir);

void main() {
  test(
    'worker reads guarded scalars and preserves unsafe ancestry and depth bound',
    () async {
      final nodes = [
        for (var i = 0; i < 258; i++) node('d$i', i == 0 ? null : 'd${i - 1}'),
        node('unsafe', null),
        node('unsafe-child', 'unsafe'),
        node('orphan', 'missing'),
        node('file', null, dir: false),
        node('under-file', 'file'),
        node('self', 'self'),
        node('cycle-a', 'cycle-b'),
        node('cycle-b', 'cycle-a'),
      ];
      final outputs = <SearchStatusAncestry>[];
      await inspectSearchStatusAncestries(
        Stream.fromIterable([
          for (var i = 0; i < nodes.length; i += 128)
            WorkerOnlyNodes(nodes.sublist(i, (i + 128).clamp(0, nodes.length))),
        ]),
        nodes.map((n) => n.id).toSet()..remove('unsafe'),
        Stream.value([
          'd256',
          'd257',
          'unsafe',
          'unsafe-child',
          'orphan',
          'file',
          'under-file',
          'self',
          'cycle-a',
        ]),
        (batch) async => outputs.addAll(batch),
      );
      expect(outputs.first.ancestry!.length, 257);
      expect(outputs.first.ancestry!.first.id, 'd0');
      expect(outputs.first.ancestry!.last.id, 'd256');
      expect(outputs[5].ancestry, [(id: 'file', name: 'file')]);
      for (final i in [1, 2, 3, 4, 6, 7, 8]) {
        expect(outputs[i].ancestry, isNull, reason: outputs[i].id);
      }
    },
  );

  test(
    'production sends ordered bounded inputs and requests and awaits each consumer',
    () async {
      final loads = <int>[];
      final requests = <int>[];
      final outputs = <int>[];
      final ids = <String>[];
      final statuses = await inspectSearchStatuses(
        snapshot: {for (var i = 0; i < 257; i++) '$i': entry('$i', null)},
        folders: [],
        cancelled: () => false,
        groupNames: (_) async => {for (var i = 0; i < 257; i++) '$i'},
        inspectAncestries: (nodes, safe, batches, consume) =>
            inspectSearchStatusAncestries(
              nodes.map((batch) {
                loads.add(batch.length);
                ids.addAll(batch.map((n) => n.id));
                return WorkerOnlyNodes(batch);
              }),
              safe,
              batches.map((batch) {
                requests.add(batch.length);
                // No second output may be requested before consuming the previous one.
                expect(outputs.length, requests.length - 1);
                return batch;
              }),
              (batch) async {
                outputs.add(batch.length);
                expect(batch.every((n) => n.ancestry!.length == 1), isTrue);
                await consume(batch);
              },
            ),
      );
      expect(loads, [128, 128, 1]);
      expect(requests, loads);
      expect(outputs, loads);
      expect(ids, [for (var i = 0; i < 257; i++) '$i']);
      expect(
        statuses.values.every((s) => s == SearchStatus.notCovered),
        isTrue,
      );
    },
  );

  for (final failure in ['none', 'producer', 'consumer']) {
    test('finally finishes and awaits real worker after $failure', () async {
      final finalized = Completer<void>();
      final release = Completer<void>();
      var done = false;
      Future<void> observed(Set<String> safe, SendPort ready) async {
        await runSearchStatusAncestryWorker(safe, ready);
        finalized.complete();
        await release.future;
      }

      Stream<List<SearchStatusNode>> nodes() async* {
        yield [node('a', null)];
        if (failure == 'producer') throw StateError('private failure');
      }

      final future = inspectSearchStatusAncestries(
        nodes(),
        {'a'},
        Stream.value(['a']),
        (_) async {
          if (failure == 'consumer') throw const SearchUnavailable();
        },
        worker: observed,
      );
      final assertion = failure == 'none'
          ? future
          : expectLater(future, throwsA(isA<SearchUnavailable>()));
      final completion = assertion.whenComplete(() => done = true);
      await finalized.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      release.complete();
      await completion;
    });
  }

  test(
    'ancestry producer failure retains snapshot and close cancellation drains',
    () async {
      final operations = SessionOperations();
      final index = AccountSearch(
        handle: 1,
        operations: operations,
        list: (_) async => [entry('a', null).file],
        decrypt: (f) => f.nameEnc,
        authorize: () {},
      );
      addTearDown(index.dispose);
      await index.rebuild();
      final revision = index.snapshotRevision;
      for (final fail in [true, false]) {
        final entered = Completer<void>();
        final release = Completer<void>();
        Stream<List<SearchStatusNode>> intercepted(
          Stream<List<SearchStatusNode>> input,
        ) async* {
          await for (final batch in input) {
            yield batch;
            entered.complete();
            if (fail) throw StateError('private producer');
            await release.future;
          }
        }

        final building = expectLater(
          index.rebuild(
            inspectStatuses: (snapshot, cancelled) => inspectSearchStatuses(
              snapshot: snapshot,
              folders: [],
              cancelled: cancelled,
              groupNames: (_) async => {'a'},
              inspectAncestries: (nodes, safe, requests, consume) =>
                  inspectSearchStatusAncestries(
                    intercepted(nodes),
                    safe,
                    requests,
                    consume,
                  ),
            ),
          ),
          throwsA(isA<SearchUnavailable>()),
        );
        await entered.future.timeout(const Duration(seconds: 10));
        if (fail) {
          await building;
          expect(index.count, 1);
        } else {
          index.close();
          var drained = false;
          final drain = operations.drain(1).then((_) => drained = true);
          await Future<void>.delayed(Duration.zero);
          expect(drained, isFalse);
          release.complete();
          await building;
          await drain;
          expect(drained, isTrue);
          expect(index.count, 0);
        }
        expect(index.snapshotRevision, revision);
      }
    },
  );

  test('invalid input and request batches fail closed and drain', () async {
    for (final input in <List<SearchStatusNode>>[
      [],
      [node('a', null), node('a', null)],
      [for (var i = 0; i < 129; i++) node('$i', null)],
    ]) {
      await expectLater(
        inspectSearchStatusAncestries(
          Stream.value(input),
          {'a'},
          const Stream.empty(),
          (_) async {},
        ),
        throwsA(isA<SearchUnavailable>()),
      );
    }
    for (final request in <List<String>>[
      [],
      ['missing'],
      List.filled(129, 'a'),
    ]) {
      await expectLater(
        inspectSearchStatusAncestries(
          Stream.value([node('a', null)]),
          {'a'},
          Stream.value(request),
          (_) async {},
        ),
        throwsA(isA<SearchUnavailable>()),
      );
    }
  });
  test(
    'production status ancestry does not walk parent map on caller',
    () async {
      final statuses = await inspectSearchStatuses(
        snapshot: NoCallerParentLookup({
          'root': entry('root', null, dir: true),
          'child': entry('child', 'root'),
        }),
        folders: [],
        cancelled: () => false,
        groupNames: (_) async => {'root', 'child'},
      );
      expect(statuses['child'], SearchStatus.notCovered);
    },
  );
}
