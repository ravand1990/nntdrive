import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:nntdrive/sync_overview_page.dart';

SyncFolderConfig folder(String id) => SyncFolderConfig(
    id: id, name: id, localPath: '/unused', remoteRootId: id);

class ProgressFieldsOnly extends MapBase<String, dynamic> {
  ProgressFieldsOnly(this.fields);
  final Map<String, dynamic> fields;
  @override
  dynamic operator [](Object? key) {
    if (!['path', 'direction', 'complete'].contains(key)) {
      throw StateError('Unused diagnostic read');
    }
    return fields[key];
  }
  @override
  Iterable<String> get keys => throw StateError('Progress enumeration');
  @override
  void operator []=(String key, dynamic value) => throw UnsupportedError('fixed');
  @override
  void clear() => throw UnsupportedError('fixed');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('fixed');
}

void main() {
  test('running transfer is one Pending exact path, not history or inspection',
      () async {
    final active = folder('active')
      ..running = true
      ..storageAccessRequired = true
      ..progress = ProgressFieldsOnly({
        'path': 'nested/exact.txt', 'direction': 'upload', 'complete': false,
      })
      ..lastReport = {'item_errors': [
        {'paths': ['nested/exact.txt'], 'code': 'remote'}
      ]};
    var calls = 0;
    final result = await buildUnsyncedOverview(
        folders: [active], inspect: (_) async { calls++; return {}; });
    expect(calls, 0);
    final row = result.entries.single;
    expect(row.path, 'nested/exact.txt');
    expect(row.status, UnsyncedStatus.pending);
    expect(row.reason, contains('Uploading'));
    expect(row.reason, isNot(contains('failed')));
    expect(row.retryable, isFalse);
    expect(row.lastAttempt, isNull);
    expect(result.counts, {UnsyncedStatus.pending: 1});
    expect(result.folders.single.counts, result.counts);
    expect(result.filtered(folderId: 'active', status: UnsyncedStatus.pending),
        [row]);
    expect(result.notices.single.message, contains('idle'));
    expect(result.notices.single.message, contains('descendants'));
  });

  test('active root fallbacks do not invent completed or unknown transfers',
      () async {
    for (final progress in <Map<String, dynamic>?>[
      null,
      {'path': 'done', 'direction': 'download', 'complete': true},
      {'path': 'wrong', 'direction': 'private diagnostic', 'complete': false},
      {'path': '', 'direction': 'upload', 'complete': false},
      {'path': ['nested diagnostic'], 'direction': 'upload', 'complete': false},
    ]) {
      final active = folder('a')..running = true..progress = progress;
      final result = await buildUnsyncedOverview(
          folders: [active], inspect: (_) async => {});
      expect(result.entries.single.path, '');
      expect(result.entries.single.isDirectory, isTrue);
      expect(result.entries.single.reason, 'Sync is running.');
    }
  });

  test('all running evidence freezes before first await even after completion',
      () async {
    final first = folder('first');
    final progress = <String, dynamic>{
      'path': 'before', 'direction': 'download', 'complete': false,
    };
    final active = folder('active')..running = true..progress = progress;
    final calls = <String>[];
    final result = await buildUnsyncedOverview(
        folders: [first, active], inspect: (f) async {
          calls.add(f.id);
          active.running = false;
          progress['path'] = 'after';
          active.progress = null;
          return {};
        });
    expect(calls, ['first']);
    expect(result.entries.single.path, 'before');
    expect(result.entries.single.reason, contains('Downloading'));
  });

  test('sync starting after freeze skips inspector and stale historical failures',
      () async {
    final first = folder('first');
    final later = folder('later')..lastReport = {'item_errors': [
      {'paths': ['live'], 'code': 'remote'}
    ]};
    final calls = <String>[];
    final result = await buildUnsyncedOverview(
        folders: [first, later], inspect: (f) async {
          calls.add(f.id);
          later.running = true;
          later.progress = {'path': 'live', 'direction': 'upload', 'complete': false};
          return {'items': [{'kind': 'upload', 'path': 'live'}]};
        });
    expect(calls, ['first']);
    expect(result.filtered(folderId: 'later').single.status, UnsyncedStatus.pending);
    expect(result.counts[UnsyncedStatus.failed], isNull);
  });

  test('controller admission marker maps to active root, not an empty comparison',
      () async {
    final result = await buildUnsyncedOverview(
        folders: [folder('a')], inspect: (_) async => {'sync_running': true});
    expect(result.entries.single.status, UnsyncedStatus.pending);
    expect(result.entries.single.path, '');
    expect(result.notices.single.message, contains('idle'));
  });

  test('active rows share global budget and retained-only counts', () async {
    final configs = [for (final id in ['a', 'b']) folder(id)..running = true];
    for (final limit in [0, 1, 2]) {
      final result = await buildUnsyncedOverview(
          folders: configs, maxEntries: limit, inspect: (_) async => {});
      expect(result.total, limit);
      expect(result.truncated, limit < 2);
      expect(result.folders.map((f) => f.total).fold(0, (int a, b) => a + b), limit);
      expect(result.filtered(status: UnsyncedStatus.pending).length, limit);
      expect(result.notices, hasLength(2));
    }
  });

  testWidgets('active evidence renders its limit and no redundant sync action',
      (tester) async {
    final active = folder('active')..running = true..progress = {
      'path': 'nested/exact.txt', 'direction': 'upload', 'complete': false,
    };
    final result = (await tester.runAsync(() => buildUnsyncedOverview(
        folders: [active], inspect: (_) async => {})))!;
    await tester.pumpWidget(MaterialApp(home: SyncOverviewPage(
        load: (_) async => result, onSyncFolder: (_) async {
          fail('Active observation must not retry');
        })));
    await tester.pumpAndSettle();
    expect(find.text('Uploading this file.'), findsOneWidget);
    expect(find.textContaining('not all active descendants'), findsOneWidget);
    expect(find.text('Everything is in sync.'), findsNothing);
    expect(find.byTooltip('Sync active now'), findsNothing);
    await tester.tap(find.text('exact.txt'));
    await tester.pumpAndSettle();
    expect(find.text('nested/exact.txt'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
