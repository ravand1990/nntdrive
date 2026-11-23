import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/storage_usage.dart';
import 'package:nntdrive/storage_usage_page.dart';

import 'storage_usage_page_test.dart' show Fixture, settled;

class Aggregator {
  final sizes = <int>[];
  final gates = <int, Completer<void>>{};
  final failures = <int>{};
  int active = 0;
  int peak = 0;

  Future<StorageUsage> call(Map<String, SearchEntry> snapshot) async {
    final size = snapshot.values.single.file.size;
    sizes.add(size);
    active++;
    if (active > peak) peak = active;
    try {
      await gates[size]?.future;
      if (failures.contains(size)) throw StateError('private diagnostic');
      return await runStorageUsage(snapshot);
    } finally {
      active--;
    }
  }
}

void main() {
  for (final obsoleteFailure in [false, true]) {
    testWidgets(
      'single flight coalesces revisions and discards obsolete ${obsoleteFailure ? 'errors' : 'results'}',
      (tester) async {
        final f = Fixture();
        final a = Aggregator();
        addTearDown(f.index.dispose);
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: StorageUsagePage(index: f.index, aggregate: a.call),
            ),
          ),
        );
        await settled(tester);
        expect(a.sizes, [12]); // Own rebuild publication is not read twice.
        a.gates[20] = Completer<void>();
        if (obsoleteFailure) a.failures.add(20);
        f.size = 20;
        await tester.runAsync(f.index.rebuild);
        expect(a.sizes, [12, 20]);
        f.size = 30;
        await tester.runAsync(f.index.rebuild);
        f.size = 40;
        await tester.runAsync(f.index.rebuild);
        f.index.remember(const SearchFilter(text: 'history'));
        expect(a.sizes, [12, 20]);
        await tester.pump();
        expect(find.text('Total: 12 bytes · 1 files'), findsOneWidget);
        a.gates[20]!.complete();
        await settled(tester);
        expect(a.sizes, [12, 20, 40]);
        expect(a.peak, 1);
        expect(find.text('Total: 40 bytes · 1 files'), findsOneWidget);
        expect(
          find.textContaining('Previous totals may be stale'),
          findsNothing,
        );
        expect(f.lists, 4);
        // Busy alone cannot aggregate, even while a listing is suspended.
        f.gate = Completer<void>();
        late Future<void> rebuild;
        await tester.runAsync(() async {
          rebuild = f.index.rebuild();
        });
        await tester.pump();
        expect(a.sizes, [12, 20, 40]);
        f.gate!.complete();
        await tester.runAsync(() => rebuild);
        await settled(tester);
        expect(a.sizes, [12, 20, 40, 40]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'failed revision retains totals, history does not retry, manual overlaps serialize',
    (tester) async {
      final f = Fixture();
      final a = Aggregator();
      addTearDown(f.index.dispose);
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: StorageUsagePage(index: f.index, aggregate: a.call),
          ),
        ),
      );
      await settled(tester);
      a.failures.add(20);
      f.size = 20;
      await tester.runAsync(f.index.rebuild);
      await settled(tester);
      expect(find.text('Total: 12 bytes · 1 files'), findsOneWidget);
      expect(
        find.textContaining('Previous totals may be stale'),
        findsOneWidget,
      );
      f.index.remember(const SearchFilter(text: 'no retry'), save: true);
      await settled(tester);
      expect(a.sizes, [12, 20]);
      expect(find.textContaining('private diagnostic'), findsNothing);
      a.failures.clear();
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      expect(a.sizes, [12, 20, 20]);
      expect(find.text('Total: 20 bytes · 1 files'), findsOneWidget);
      a.gates[30] = Completer<void>();
      f.size = 30;
      await tester.runAsync(f.index.rebuild);
      await tester.pump();
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      expect(f.lists, 4); // Manual waits for already admitted aggregate.
      expect(a.peak, 1);
      a.gates[30]!.complete();
      await settled(tester);
      expect(f.lists, 5);
      expect(a.sizes, [12, 20, 20, 30, 30]);
      expect(a.peak, 1);
      expect(find.textContaining('Previous totals may be stale'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final close in [false, true]) {
    testWidgets(
      'suspended aggregate drains without follow-up after ${close ? 'close' : 'dispose'}',
      (tester) async {
        final f = Fixture();
        final a = Aggregator();
        addTearDown(f.index.dispose);
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: StorageUsagePage(index: f.index, aggregate: a.call),
            ),
          ),
        );
        await settled(tester);
        a.gates[20] = Completer<void>();
        f.size = 20;
        await tester.runAsync(f.index.rebuild);
        f.size = 30;
        await tester.runAsync(f.index.rebuild);
        await tester.pump();
        await tester.runAsync(
          () => tester.tap(find.byTooltip('Refresh storage usage')),
        );
        expect(f.lists, 3); // Queued manual refresh has not rebuilt yet.
        var drained = false;
        if (close) {
          f.index.close();
          f.index.operations.drain(1).then((_) => drained = true);
          await tester.pump();
          expect(drained, isFalse);
          expect(find.textContaining('Total:'), findsNothing);
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        a.gates[20]!.complete();
        await tester.runAsync(() async {
          for (var i = 0; i < 500 && a.active != 0; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        expect(a.active, 0);
        expect(f.lists, 3);
        expect(a.sizes, [12, 20]);
        if (close) expect(drained, isTrue);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
