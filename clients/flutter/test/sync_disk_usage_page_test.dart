import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/storage_usage_page.dart';
import 'package:nntdrive/sync_disk_usage.dart';

import 'storage_usage_page_test.dart' show Fixture, settled;

Future<void> scrollTo(WidgetTester tester, Finder target) async {
  await tester.drag(find.byType(ListView).first, const Offset(0, 5000));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    target,
    150,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  testWidgets('separate sync disk section is explicit when unavailable', (
    tester,
  ) async {
    final f = Fixture()..offline = true;
    addTearDown(f.index.dispose);
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(home: StorageUsagePage(index: f.index)),
      ),
    );
    await settled(tester);
    await scrollTo(tester, find.text('This device · sync-folder file lengths'));
    await scrollTo(tester, find.textContaining('Not journal equality'));
    expect(find.textContaining('Not journal equality'), findsOneWidget);
    await scrollTo(tester, find.text('Sync-folder usage unavailable. Refresh to retry.'));
    expect(
      find.text('Sync-folder usage unavailable. Refresh to retry.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'independent offline reading refresh failure and close are explicit',
    (tester) async {
      final f = Fixture()..offline = true;
      addTearDown(f.index.dispose);
      var calls = 0;
      var fail = false;
      var bytes = 7;
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: StorageUsagePage(
              index: f.index,
              readSyncUsage: () async {
                calls++;
                if (fail) throw StateError('private path secret');
                return SyncDiskUsage([
                  SyncDiskRootUsage(SyncDiskState.complete, bytes, 1, 0),
                  const SyncDiskRootUsage(SyncDiskState.incomplete, 3, 1, 1),
                  const SyncDiskRootUsage(SyncDiskState.overlap, 0, 0, 0),
                  const SyncDiskRootUsage(SyncDiskState.unavailable, 0, 0, 0),
                ]);
              },
            ),
          ),
        ),
      );
      await settled(tester);
      await scrollTo(tester, find.textContaining('Sync root 1:'));
      expect(find.textContaining('7 measured bytes'), findsOneWidget);
      await scrollTo(tester, find.textContaining('3 observed bytes'));
      expect(find.textContaining('3 observed bytes'), findsOneWidget);
      await scrollTo(tester, find.textContaining('Not measured: overlapping'));
      expect(find.textContaining('Not measured: overlapping'), findsOneWidget);
      await scrollTo(tester, find.textContaining('Unavailable: missing'));
      expect(find.textContaining('Unavailable: missing'), findsOneWidget);
      expect(calls, 1);
      fail = true;
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      await scrollTo(
        tester,
        find.textContaining('Previous observations may be stale'),
      );
      expect(find.textContaining('Previous observations may be stale'), findsOneWidget);
      await scrollTo(tester, find.textContaining('7 measured bytes'));
      expect(find.textContaining('7 measured bytes'), findsOneWidget);
      expect(find.textContaining('private path'), findsNothing);
      fail = false;
      bytes = 9;
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      await scrollTo(tester, find.textContaining('9 measured bytes'));
      expect(
        find.textContaining('Previous observations may be stale'),
        findsNothing,
      );
      f.index.close();
      await tester.pump();
      expect(find.textContaining('9 measured bytes'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending refresh is single flight and late close/dispose never publishes',
    (tester) async {
      for (final close in [false, true]) {
        final f = Fixture()..offline = true;
        final gate = Completer<SyncDiskUsage>();
        var calls = 0;
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: StorageUsagePage(
                index: f.index,
                readSyncUsage: () {
                  calls++;
                  return gate.future;
                },
              ),
            ),
          ),
        );
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton &&
                      widget.tooltip == 'Refresh storage usage',
                ),
              )
              .onPressed,
          isNull,
        );
        if (close) {
          f.index.close();
          await tester.pump();
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        gate.complete(
          SyncDiskUsage([
            const SyncDiskRootUsage(SyncDiskState.complete, 99, 1, 0),
          ]),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
        expect(calls, 1);
        expect(find.textContaining('99 measured bytes'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        f.index.dispose();
      }
    },
  );
}
