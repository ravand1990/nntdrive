import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/cache_duplicates.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:nntdrive/storage_usage_page.dart';

import 'storage_usage_page_test.dart' show Fixture, settled;

CacheDuplicateReview result({bool partial = true}) => CacheDuplicateReview(
  groups: [
    [
      for (final id in ['opaque-a', 'opaque-b'])
        CachedDownload(
          fileId: id,
          revisionId: 'revision',
          fileName: '${'a' * 32}.bin',
          sizeBytes: 7,
          storedAt: DateTime.utc(2020),
          lastUsedAt: DateTime.utc(2020),
          pinned: id == 'opaque-a',
        ),
    ],
  ],
  examined: 3,
  excluded: 1,
  bytesRead: 28,
  partial: partial,
);

Future<void> reviewVisible(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('Review exact cache duplicates'),
    300,
    scrollable: find.byType(Scrollable).first,
  );
}

void main() {
  testWidgets(
    'explicit read-only review, single flight, partial scope and retry',
    (tester) async {
      final f = Fixture()..offline = true;
      addTearDown(f.index.dispose);
      var calls = 0;
      final gate = Completer<CacheDuplicateReview>();
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: StorageUsagePage(
              index: f.index,
              reviewCacheDuplicates: () {
                calls++;
                if (calls == 1) return gate.future;
                if (calls == 2) {
                  throw StateError('private path must not render');
                }
                return Future.value(result(partial: false));
              },
            ),
          ),
        ),
      );
      await settled(tester);
      expect(calls, 0);
      await reviewVisible(tester);
      final action = tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Review exact cache duplicates'),
          )
          .onPressed!;
      action();
      action();
      await tester.pump();
      expect(calls, 1);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      gate.complete(result());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.textContaining('File opaque-b'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('File opaque-a · revision revision · pinned'),
        findsOneWidget,
      );
      expect(find.textContaining('Partial review:'), findsOneWidget);
      expect(
        find.textContaining('Exact group 1 · 7 bytes per copy'),
        findsOneWidget,
      );
      await reviewVisible(tester);
      await tester.tap(find.text('Review exact cache duplicates'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cache review failed.'), findsOneWidget);
      expect(find.textContaining('private path must not render'), findsNothing);
      await tester.tap(find.text('Review exact cache duplicates'));
      await tester.pumpAndSettle();
      expect(
        find.text('Review completed within the indexed-copy scope.'),
        findsOneWidget,
      );
      expect(calls, 3);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final close in [false, true]) {
    testWidgets(
      'late review rejected on ${close ? 'session close' : 'page disposal'}',
      (tester) async {
        final f = Fixture()..offline = true;
        addTearDown(f.index.dispose);
        final gate = Completer<CacheDuplicateReview>();
        var calls = 0;
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: StorageUsagePage(
                index: f.index,
                reviewCacheDuplicates: () {
                  calls++;
                  return gate.future;
                },
              ),
            ),
          ),
        );
        await settled(tester);
        await reviewVisible(tester);
        final action = tester
            .widget<FilledButton>(
              find.widgetWithText(
                FilledButton,
                'Review exact cache duplicates',
              ),
            )
            .onPressed!;
        action();
        await tester.pump();
        if (close) {
          f.index.close();
          await tester.pump();
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        gate.complete(result());
        await tester.pumpAndSettle();
        expect(find.textContaining('Exact group 1'), findsNothing);
        expect(calls, 1);
        action(); // A captured callback must not resurrect a closed/disposed page.
        expect(calls, 1);
        if (close) {
          await tester.pumpWidget(const SizedBox());
        }
      },
    );
  }
}
