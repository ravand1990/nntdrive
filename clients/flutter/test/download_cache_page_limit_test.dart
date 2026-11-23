import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/cache_page.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late DownloadCache cache;
  late DownloadCache roomy;
  late DownloadCache tiny;
  late DownloadCache oversized;

  // All cache directories and copies are created here, never inside a widget
  // test body: awaiting real directory IO in a testWidgets body can hang until
  // the per-test timeout.
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('nntdrive-cache-limit-ui');

    cache = DownloadCache(
      root: Directory(p.join(sandbox.path, 'cache')),
      limitBytes: 1024 * 1024,
    );
    await cache.open();
    oversized = DownloadCache(
      root: Directory(p.join(sandbox.path, 'oversized')),
      limitBytes: 1000,
    );
    await oversized.open();
    final latest = File(p.join(sandbox.path, 'latest.bin'));
    await latest.writeAsBytes(List<int>.filled(600, 7));
    await oversized.store(fileId: 'latest', revisionId: 'r1', source: latest);
    await oversized.setLimit(100);

    roomy = DownloadCache(
      root: Directory(p.join(sandbox.path, 'roomy')),
      limitBytes: 2 * 1024 * 1024 * 1024,
    );
    await roomy.open();

    // A cache whose only remaining copy is pinned and larger than its limit:
    // the screen must warn instead of deleting it.
    tiny = DownloadCache(
      root: Directory(p.join(sandbox.path, 'tiny')),
      limitBytes: 1024,
    );
    await tiny.open();
    final pinned = File(p.join(sandbox.path, 'pinned.bin'));
    await pinned.writeAsBytes(List<int>.filled(4096, 5));
    await tiny.store(
      fileId: 'file-pinned',
      revisionId: 'rev-1',
      source: pinned,
      pinned: true,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  Widget page(
    DownloadCache cache, {
    Future<int?> Function(Directory root)? freeSpace,
    Future<bool> Function(int bytes)? onLimitChanged,
  }) => MaterialApp(
    home: DownloadCachePage(
      cache: cache,
      nameFor: (id) => id == 'file-pinned' ? 'Pinned report.pdf' : '',
      freeSpaceReader: freeSpace,
      onLimitChanged: onLimitChanged,
    ),
  );

  testWidgets('shows the real device free space next to the cache totals', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(cache, freeSpace: (_) async => 3 * 1024 * 1024 * 1024),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('3.0 GiB free on this device'), findsOneWidget);
    expect(
      find.textContaining('less free space than the'),
      findsNothing,
      reason: 'plenty of room, so no device-space warning',
    );
  });

  testWidgets('says so plainly when the device reading is unavailable', (
    tester,
  ) async {
    await tester.pumpWidget(page(cache, freeSpace: (_) async => null));
    await tester.pumpAndSettle();

    expect(
      find.text('Device free space is unavailable on this build.'),
      findsOneWidget,
    );
  });

  testWidgets('warns when the device has less room than the cache limit', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(roomy, freeSpace: (_) async => 500 * 1024 * 1024),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('500.0 MiB free on this device'),
      findsOneWidget,
    );
    expect(
      find.textContaining('less free space than the cache limit'),
      findsOneWidget,
    );
  });

  testWidgets('warns instead of deleting copies kept offline above the limit', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(tiny, freeSpace: (_) async => 8 * 1024 * 1024 * 1024),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('the copies kept offline are larger than the limit'),
      findsOneWidget,
    );
    expect(find.text('Pinned report.pdf'), findsOneWidget);
    expect(tiny.usage.pinnedBytes, 4096, reason: 'pinned copies are kept');
  });

  testWidgets('explains a protected newest copy above the limit', (
    tester,
  ) async {
    await tester.pumpWidget(page(oversized, freeSpace: (_) async => 1 << 40));
    await tester.pumpAndSettle();
    expect(find.textContaining('newest downloaded copy'), findsOneWidget);
    expect(oversized.find('latest'), isNotNull);
    expect(oversized.usage.usedBytes, 600);
  });

  testWidgets('applies a preset limit and reports it as saved', (tester) async {
    int? saved;
    await tester.pumpWidget(
      page(
        cache,
        freeSpace: (_) async => 8 * 1024 * 1024 * 1024,
        onLimitChanged: (bytes) async {
          saved = bytes;
          return true;
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change the cache limit'));
    await tester.pumpAndSettle();
    expect(find.text('Cache limit'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '512.0 MiB'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(cache.limitBytes, 512 * 1024 * 1024);
    expect(saved, 512 * 1024 * 1024);
    expect(find.textContaining('Cache limit is now 512.0 MiB'), findsOneWidget);
    expect(find.textContaining('of a 512.0 MiB limit'), findsOneWidget);
  });

  testWidgets('applies a typed limit such as 300 MiB', (tester) async {
    await tester.pumpWidget(page(cache, freeSpace: (_) async => 1 << 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change the cache limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '300 MiB');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(cache.limitBytes, 300 * 1024 * 1024);
  });

  testWidgets('rejects an unusable typed limit without applying it', (
    tester,
  ) async {
    await tester.pumpWidget(page(cache, freeSpace: (_) async => 1 << 40));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change the cache limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '8 MiB');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Enter a size between 16 MiB and 1 TiB'),
      findsOneWidget,
    );
    expect(cache.limitBytes, 1024 * 1024, reason: 'nothing changed');
    expect(
      find.text('Cache limit'),
      findsOneWidget,
      reason: 'dialog stays open',
    );
  });

  testWidgets('says when a limit applies but could not be saved', (
    tester,
  ) async {
    await tester.pumpWidget(
      page(
        cache,
        freeSpace: (_) async => 8 * 1024 * 1024 * 1024,
        onLimitChanged: (_) async => false,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Change the cache limit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '256 MiB');
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(cache.limitBytes, 256 * 1024 * 1024);
    expect(
      find.textContaining('could not be saved for the next start'),
      findsOneWidget,
    );
  });
}
