import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/session_operations.dart';

RemoteFile item(int size) =>
    RemoteFile.fromJson({'id': 'file', 'name_enc': 'sealed', 'size': size});

void main() {
  test(
    'lazy mutation refresh coalesces bursts and suspended follow-ups',
    () async {
      final operations = SessionOperations();
      var calls = 0;
      var active = 0;
      var maximum = 0;
      var size = 1;
      Completer<void>? gate;
      Completer<void>? entered;
      final index = AccountSearch(
        handle: 1,
        operations: operations,
        authorize: () {},
        decrypt: (_) => 'private.txt',
        list: (_) async {
          calls++;
          active++;
          if (active > maximum) maximum = active;
          final observed = size;
          entered?.complete();
          entered = null;
          await gate?.future;
          active--;
          return [item(observed)];
        },
      );
      addTearDown(index.dispose);
      await index.refreshAfterMutation();
      expect(calls, 0);
      await index.rebuild();
      expect(calls, 1);
      size = 2;
      gate = Completer<void>();
      entered = Completer<void>();
      final started = entered!.future;
      final refresh = index.refreshAfterMutation();
      for (var i = 0; i < 20; i++) {
        expect(identical(index.refreshAfterMutation(), refresh), isTrue);
      }
      await started;
      expect(calls, 2);
      expect((await index.readSnapshot((s) async => s['file']!.file.size)), 1);
      size = 3;
      for (var i = 0; i < 20; i++) {
        index.refreshAfterMutation();
      }
      final first = gate;
      gate = null;
      first.complete();
      await refresh;
      expect(calls, 3);
      expect(maximum, 1);
      expect(index.snapshotRevision, 3);
      expect((await index.readSnapshot((s) async => s['file']!.file.size)), 3);
      index.remember(const SearchFilter(text: 'private'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, 3);
    },
  );

  test(
    'mutation during manual build requires fresh follow-up; errors retain snapshot',
    () async {
      var size = 1;
      var calls = 0;
      var fail = false;
      Completer<void>? gate;
      final index = AccountSearch(
        handle: 2,
        operations: SessionOperations(),
        authorize: () {},
        decrypt: (_) => 'private.txt',
        list: (_) async {
          calls++;
          final observed = size;
          await gate?.future;
          if (fail) throw StateError('private diagnostic');
          return [item(observed)];
        },
      );
      addTearDown(index.dispose);
      await index.rebuild();
      gate = Completer<void>();
      final manual = index.rebuild();
      size = 9;
      final refresh = index.refreshAfterMutation();
      final held = gate;
      gate = null;
      held.complete();
      await manual;
      await refresh;
      expect(calls, 3);
      expect((await index.readSnapshot((s) async => s['file']!.file.size)), 9);
      fail = true;
      await index.refreshAfterMutation();
      expect(index.failed, isTrue);
      expect(index.ready, isTrue);
      expect(index.snapshotRevision, 3);
      expect((await index.readSnapshot((s) async => s['file']!.file.size)), 9);
      await Future<void>.delayed(Duration.zero);
      expect(calls, 4); // No automatic error retry.
      fail = false;
      await index.refreshAfterMutation();
      expect(index.failed, isFalse);
      expect(index.snapshotRevision, 4);
    },
  );

  test(
    'close rejects new refreshes and drains admitted queue and listing',
    () async {
      final operations = SessionOperations();
      var calls = 0;
      Completer<void>? gate;
      final entered = Completer<void>();
      final index = AccountSearch(
        handle: 3,
        operations: operations,
        authorize: () {},
        decrypt: (_) => 'private',
        list: (_) async {
          calls++;
          if (gate != null) entered.complete();
          await gate?.future;
          return [item(1)];
        },
      );
      addTearDown(index.dispose);
      await index.rebuild();
      gate = Completer<void>();
      final refresh = index.refreshAfterMutation();
      await entered.future;
      index
          .refreshAfterMutation(); // Pending work must not restart after close.
      index.close();
      var drained = false;
      final drain = operations.drain(3).then((_) => drained = true);
      await index.refreshAfterMutation();
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      expect(index.count, 0);
      gate.complete();
      await refresh;
      await drain;
      expect(calls, 2);
      expect(index.snapshotRevision, 1);
      expect(index.ready, isFalse);
    },
  );

  test('close before event turn drains queue without starting HTTP', () async {
    final operations = SessionOperations();
    var calls = 0;
    final index = AccountSearch(
      handle: 4,
      operations: operations,
      authorize: () {},
      decrypt: (_) => 'private',
      list: (_) async {
        calls++;
        return [item(1)];
      },
    );
    addTearDown(index.dispose);
    await index.rebuild();
    final refresh = index.refreshAfterMutation();
    index.close();
    await operations.drain(4);
    await refresh;
    expect(calls, 1);
  });
}
