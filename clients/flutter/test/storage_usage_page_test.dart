import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/storage_usage_page.dart';

class Fixture {
  bool offline = false;
  int size = 12;
  int lists = 0;
  Completer<void>? gate;
  late final index = AccountSearch(
    handle: 1,
    operations: SessionOperations(),
    list: (_) async {
      lists++;
      await gate?.future;
      if (offline) throw StateError('private filename or token');
      return [RemoteFile('f', null, 'opaque', false, size, false, 1, null)];
    },
    decrypt: (_) => 'Private.txt',
    authorize: () {},
  );
}

Future<void> settled(WidgetTester tester) async {
  for (var i = 0; i < 500; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
    if (find.byType(LinearProgressIndicator).evaluate().isEmpty) return;
  }
  fail('storage refresh did not finish');
}

void main() {
  testWidgets(
    'loading, exact totals, failed refresh retention, retry and close',
    (tester) async {
      final f = Fixture();
      addTearDown(f.index.dispose);
      f.gate = Completer<void>();
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(home: StorageUsagePage(index: f.index)),
        ),
      );
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      f.gate!.complete();
      f.gate = null;
      await settled(tester);
      expect(find.text('Total: 12 bytes · 1 files'), findsOneWidget);
      f.offline = true;
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      expect(
        find.textContaining('Previous totals may be stale'),
        findsOneWidget,
      );
      expect(find.text('Total: 12 bytes · 1 files'), findsOneWidget);
      expect(find.textContaining('private filename or token'), findsNothing);
      f.offline = false;
      f.size = 27;
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      expect(find.text('Total: 27 bytes · 1 files'), findsOneWidget);
      expect(find.textContaining('Previous totals may be stale'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      f.size = 35;
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(home: StorageUsagePage(index: f.index)),
        ),
      );
      await settled(tester);
      expect(find.text('Total: 35 bytes · 1 files'), findsOneWidget);
      f.index.close();
      await tester.pump();
      expect(find.textContaining('Unlock again'), findsOneWidget);
      expect(find.text('Total: 35 bytes · 1 files'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'initial error, offline session reuse and changed snapshot warning',
    (tester) async {
      final f = Fixture()..offline = true;
      addTearDown(f.index.dispose);
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(home: StorageUsagePage(index: f.index)),
        ),
      );
      await settled(tester);
      expect(
        find.text('Storage usage unavailable. Refresh to retry.'),
        findsOneWidget,
      );
      f.offline = false;
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      await tester.pumpWidget(const SizedBox());
      f.offline = true;
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(home: StorageUsagePage(index: f.index)),
        ),
      );
      await settled(tester);
      expect(find.text('Total: 12 bytes · 1 files'), findsOneWidget);
      expect(
        find.textContaining('Previous totals may be stale'),
        findsOneWidget,
      );
      f.offline = false;
      f.size = 40;
      await tester.runAsync(f.index.rebuild);
      await tester.pump();
      expect(find.text('Total: 12 bytes · 1 files'), findsOneWidget);
      expect(
        find.textContaining('Previous totals may be stale'),
        findsOneWidget,
      );
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      expect(find.text('Total: 40 bytes · 1 files'), findsOneWidget);
      expect(find.textContaining('Previous totals may be stale'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('dispose during listing admits no aggregate publication', (
    tester,
  ) async {
    final f = Fixture();
    addTearDown(f.index.dispose);
    f.gate = Completer<void>();
    await tester.runAsync(
      () => tester.pumpWidget(
        MaterialApp(home: StorageUsagePage(index: f.index)),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    f.gate!.complete();
    await tester.runAsync(() async {
      while (f.index.building) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
