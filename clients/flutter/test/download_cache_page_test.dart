import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/cache_page.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late DownloadCache cache;
  late DownloadCache empty;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('nntdrive-cache-page-test');
    final root = Directory(p.join(sandbox.path, 'download-cache'));
    cache = DownloadCache(root: root, limitBytes: 1024 * 1024);
    await cache.open();
    empty = DownloadCache(
      root: Directory(p.join(sandbox.path, 'empty-cache')),
      limitBytes: 1024 * 1024,
    );
    await empty.open();
    final pinned = File(p.join(sandbox.path, 'pinned.bin'));
    await pinned.writeAsBytes(List<int>.filled(2048, 3));
    await cache.store(
      fileId: 'file-pinned',
      revisionId: 'rev-1',
      source: pinned,
      pinned: true,
    );
    final scratch = File(p.join(sandbox.path, 'scratch.bin'));
    await scratch.writeAsBytes(List<int>.filled(1024, 4));
    await cache.store(
      fileId: 'file-scratch',
      revisionId: 'rev-1',
      source: scratch,
    );
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  testWidgets('lists cached copies with their pin state and totals', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadCachePage(
          cache: cache,
          nameFor: (id) => id == 'file-pinned' ? 'Pinned report.pdf' : '',
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Offline copies & cache'), findsOneWidget);
    expect(find.textContaining('3.0 KiB cached'), findsOneWidget);
    expect(find.textContaining('2.0 KiB kept offline'), findsOneWidget);
    expect(find.text('Pinned report.pdf'), findsOneWidget);
    // An entry with no known local name falls back to an opaque short ID.
    expect(find.text('Cached item file-scr'), findsOneWidget);
    expect(find.byTooltip('Clear unpinned cache'), findsOneWidget);
    expect(find.byIcon(Icons.offline_pin), findsOneWidget);

    // The browser is told to never treat sync-folder or local-only files as
    // cache content.
    expect(
      find.textContaining('Files inside sync folders, local-only files'),
      findsOneWidget,
    );
  });

  testWidgets('an empty cache explains how to keep a file offline', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadCachePage(cache: empty, nameFor: (_) => ''),
      ),
    );
    await tester.pump();

    expect(
      find.textContaining('No downloaded copies are cached'),
      findsOneWidget,
    );
    expect(find.textContaining('Keep offline'), findsOneWidget);
  });
}
