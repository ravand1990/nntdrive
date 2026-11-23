import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:nntdrive/storage_usage_page.dart';
import 'package:path/path.dart' as p;

import 'storage_usage_page_test.dart' show Fixture, settled;

const before = MeasuredCacheUsage(
  bytes: 13,
  copies: 2,
  pinnedBytes: 9,
  pinnedCopies: 1,
  excludedCopies: 0,
);
const after = MeasuredCacheUsage(
  bytes: 9,
  copies: 1,
  pinnedBytes: 9,
  pinnedCopies: 1,
  excludedCopies: 0,
);
const cleanup = CacheCleanup(
  removedEntries: 1,
  freedBytes: 17,
  keptPinnedEntries: 1,
);

Future<void> openDialog(WidgetTester tester) async {
  await tester.tap(find.text('Clear unpinned cache'));
  await tester.pumpAndSettle();
  expect(find.text('Clear unpinned cache?'), findsOneWidget);
}

void main() {
  testWidgets(
    'confirmed cleanup uses real disk lengths and refreshes pinned totals offline',
    (tester) async {
      final f = Fixture()..offline = true;
      addTearDown(f.index.dispose);
      late Directory dir;
      late DownloadCache cache;
      late CachedDownload unpinned;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('dashboard-cleanup');
        cache = DownloadCache(root: Directory(p.join(dir.path, 'cache')));
        await cache.open();
        final source = File(p.join(dir.path, 'source'));
        await source.writeAsBytes(List.filled(9, 1));
        await cache.store(
          fileId: 'pin',
          revisionId: 'r',
          source: source,
          pinned: true,
        );
        await source.writeAsBytes(List.filled(4, 1));
        unpinned = await cache.store(
          fileId: 'scratch',
          revisionId: 'r',
          source: source,
        );
      });
      addTearDown(() => dir.delete(recursive: true));
      var calls = 0;
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: StorageUsagePage(
              index: f.index,
              readCacheUsage: cache.measureUsage,
              clearUnpinnedCache: () {
                calls++;
                return cache.clearUnpinned();
              },
            ),
          ),
        ),
      );
      await settled(tester);
      expect(find.text('Cache total: 13 bytes · 2 copies'), findsOneWidget);
      await openDialog(tester);
      expect(calls, 0);
      expect(
        find.textContaining(
          'Pinned copies, sync folders and account files stay',
        ),
        findsOneWidget,
      );
      await tester.runAsync(
        () => cache.fileFor(unpinned).writeAsBytes(List.filled(17, 7)),
      );
      await tester.runAsync(() => tester.tap(find.text('Clear')));
      for (
        var i = 0;
        i < 200 && find.text('Cache cleanup pending…').evaluate().isNotEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        find.textContaining(
          'Removed 1 cached copies and reclaimed 17 measured bytes',
        ),
        findsOneWidget,
      );
      expect(find.text('Cache total: 9 bytes · 1 copies'), findsOneWidget);
      expect(find.text('Pinned: 9 bytes · 1 copies'), findsOneWidget);
      await tester.runAsync(() async {
        expect(await cache.fileFor(unpinned).exists(), isFalse);
        expect(await cache.fileFor(cache.entries.single).length(), 9);
      });
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'cancel, barrier dismissal and duplicate dialog admission never delete',
    (tester) async {
      final f = Fixture();
      addTearDown(f.index.dispose);
      var calls = 0;
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: StorageUsagePage(
              index: f.index,
              readCacheUsage: () async => before,
              clearUnpinnedCache: () async {
                calls++;
                return cleanup;
              },
            ),
          ),
        ),
      );
      await settled(tester);
      final action = tester
          .widget<OutlinedButton>(find.byType(OutlinedButton))
          .onPressed!;
      action();
      action();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      await openDialog(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(calls, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failure refreshes partial changes, failed refresh warns and retry recovers',
    (tester) async {
      final f = Fixture();
      addTearDown(f.index.dispose);
      var reads = 0;
      var failedRead = false;
      var failedClear = true;
      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: StorageUsagePage(
              index: f.index,
              readCacheUsage: () async {
                reads++;
                if (failedRead) throw StateError('private path');
                return reads == 1 ? before : after;
              },
              clearUnpinnedCache: () async {
                if (failedClear) throw StateError('private path');
                return const CacheCleanup(
                  removedEntries: 0,
                  freedBytes: 0,
                  keptPinnedEntries: 1,
                  failedEntries: 1,
                );
              },
            ),
          ),
        ),
      );
      await settled(tester);
      failedRead = true;
      await openDialog(tester);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(
        find.textContaining('some copies may already have been removed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Previous cache totals may be stale'),
        findsOneWidget,
      );
      expect(find.textContaining('private path'), findsNothing);
      expect(
        tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
        isNull,
      );
      failedRead = false;
      await tester.runAsync(
        () => tester.tap(find.byTooltip('Refresh storage usage')),
      );
      await settled(tester);
      expect(find.text('Cache total: 9 bytes · 1 copies'), findsOneWidget);
      failedClear = false;
      await openDialog(tester);
      await tester.tap(find.text('Clear'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1 copies could not be removed'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Previous cache totals may be stale'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final close in [true, false]) {
    testWidgets(
      '${close ? 'close' : 'dispose'} during confirmation prevents deletion',
      (tester) async {
        final f = Fixture();
        addTearDown(f.index.dispose);
        var calls = 0;
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: StorageUsagePage(
                index: f.index,
                readCacheUsage: () async => before,
                clearUnpinnedCache: () async {
                  calls++;
                  return cleanup;
                },
              ),
            ),
          ),
        );
        await settled(tester);
        await openDialog(tester);
        if (close) {
          f.index.close();
          await tester.pump();
          await tester.tap(find.text('Clear'));
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        await tester.pumpAndSettle();
        expect(calls, 0);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );

    testWidgets(
      '${close ? 'close' : 'dispose'} during cleanup suppresses late results and reads',
      (tester) async {
        final f = Fixture();
        addTearDown(f.index.dispose);
        var reads = 0;
        var calls = 0;
        final gate = Completer<CacheCleanup>();
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: StorageUsagePage(
                index: f.index,
                readCacheUsage: () async {
                  reads++;
                  return before;
                },
                clearUnpinnedCache: () {
                  calls++;
                  return gate.future;
                },
              ),
            ),
          ),
        );
        await settled(tester);
        await openDialog(tester);
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(
          tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
          isNull,
        );
        if (close) {
          f.index.close();
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        gate.complete(cleanup);
        await tester.pumpAndSettle();
        expect(reads, 1);
        expect(find.textContaining('reclaimed'), findsNothing);
        expect(find.textContaining('Cache total:'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
