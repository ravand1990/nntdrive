import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/search_status_names.dart';

class WorkerOnlyBatch extends ListBase<SearchStatusName> {
  WorkerOnlyBatch(this.values);
  final List<SearchStatusName> values;
  final int caller = Isolate.current.hashCode;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  SearchStatusName operator [](int index) {
    if (Isolate.current.hashCode == caller) {
      throw StateError('Name grouping ran on the caller isolate');
    }
    return values[index];
  }

  @override
  void operator []=(int index, SearchStatusName value) =>
      throw UnsupportedError('immutable');
}

void main() {
  test('name validation and canonical grouping execute away from caller',
      () async {
    final safe = await groupSearchStatusNames(Stream.fromIterable([
      WorkerOnlyBatch([
        (id: 'accent', parent: 'root', name: 'é'),
        (id: 'clean', parent: 'root', name: 'safe'),
        (id: 'bad', parent: 'invalid', name: '../escape'),
        (id: 'blocked', parent: 'invalid', name: 'otherwise safe'),
      ]),
      WorkerOnlyBatch([
        (id: 'alias', parent: 'root', name: 'E\u0301'),
        (id: 'other-parent', parent: 'separate', name: 'é'),
      ]),
    ]));
    expect(safe, {'clean', 'other-parent'});
  });

  test('bounded batches retain complete sibling groups across batch boundaries',
      () async {
    final safe = await groupSearchStatusNames(Stream.fromIterable([
      [
        for (var i = 0; i < 128; i++) (id: 'f$i', parent: null, name: 'Name$i'),
      ],
      [(id: 'late', parent: null, name: 'NAME0')],
    ]));
    expect(safe.length, 127);
    expect(safe, isNot(contains('f0')));
    expect(safe, isNot(contains('late')));
    expect(safe, contains('f127'));
  });

  test('empty snapshot succeeds and malformed batches fail redacted', () async {
    expect(await groupSearchStatusNames(const Stream.empty()), isEmpty);
    for (final batches in <List<List<SearchStatusName>>>[
      [[]],
      [
        [for (var i = 0; i < 129; i++) (id: '$i', parent: null, name: 'n$i')]
      ],
      [
        [(id: 'duplicate', parent: null, name: 'first')],
        [(id: 'duplicate', parent: 'other', name: 'second')]
      ],
    ]) {
      await expectLater(groupSearchStatusNames(Stream.fromIterable(batches)),
          throwsA(isA<SearchUnavailable>()));
    }
  });

  test('producer failure still finishes the worker', () async {
    Stream<List<SearchStatusName>> batches() async* {
      yield [(id: 'ok', parent: null, name: 'safe')];
      throw const SearchUnavailable();
    }

    await expectLater(
        groupSearchStatusNames(batches()), throwsA(isA<SearchUnavailable>()));
    // A subsequent worker remains usable after the first workflow drained.
    expect(
        await groupSearchStatusNames(
            Stream.value([(id: 'next', parent: null, name: 'safe')])),
        {'next'});
  });
}
