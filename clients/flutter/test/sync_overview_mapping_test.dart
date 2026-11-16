import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

// Sendable JSON-shaped input whose access proves the mapping location, not
// merely the location of the final ordering comparator.
class WorkerPlan extends MapBase<String, dynamic> {
  WorkerPlan(this.caller);
  final SendPort caller;
  @override
  dynamic operator [](Object? key) {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Plan mapping ran on caller');
    }
    return switch (key) {
      'items' => [
          {'kind': 'upload', 'path': 'only', 'size': 7},
        ],
      _ => null,
    };
  }

  @override
  Iterable<String> get keys => ['items'];
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('fixed');
  @override
  void clear() => throw UnsupportedError('fixed');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('fixed');
}

SyncFolderConfig folder(String id) => SyncFolderConfig(
      id: id,
      name: id,
      localPath: '/unused',
      remoteRootId: id,
    );

void main() {
  test('whole builder maps plan off caller with unsendable inspector context',
      () async {
    final port = ReceivePort();
    addTearDown(port.close);
    final overview = await buildUnsyncedOverview(
      folders: [folder('f')],
      inspect: (_) async {
        expect(port.sendPort, isA<SendPort>());
        return WorkerPlan(Isolate.current.controlPort);
      },
    );
    expect(overview.notices, isEmpty);
    expect(overview.entries.single.path, 'only');
    expect(overview.entries.single.size, 7);
    expect(overview.folders.single.counts, {UnsyncedStatus.localOnly: 1});
  });

  test('single-row mapping yields an event turn without an ordering worker',
      () async {
    var eventTurn = false;
    final overview = await buildUnsyncedOverview(
      folders: [folder('f')],
      inspect: (_) async {
        Timer.run(() => eventTurn = true);
        return {
          'items': [
            {'kind': 'upload', 'path': 'one'}
          ]
        };
      },
    );
    expect(overview.total, 1);
    expect(eventTurn, isTrue);
  });

  test('freezes all config and nested report paths before any await', () async {
    final a = folder('a');
    final b = folder('b');
    b.lastSync = 'before';
    b.excluded = ['private\\folder'];
    final paths = ['failed'];
    b.lastReport = {
      'item_errors': [
        {'paths': paths, 'code': 'remote'}
      ],
      'skipped': [
        ['link', 'special file']
      ],
    };
    final overview = await buildUnsyncedOverview(
      folders: [a, b],
      inspect: (f) async {
        if (f.id == 'a') {
          b.name = 'changed';
          b.lastSync = 'after';
          b.excluded.clear();
          paths.clear();
          b.lastReport!.clear();
          return <String, dynamic>{};
        }
        return {
          'items': [
            {'kind': 'upload', 'path': 'failed'},
            {
              'kind': 'rename_local',
              'path': 'old',
              'path_to': 'new',
              'is_dir': true
            },
          ],
          'folder_moves_pending': true,
          'journal_available': false,
          'truncated': true,
        };
      },
    );
    expect(overview.entries.every((e) => e.folderName == 'b'), isTrue);
    expect(overview.entries.every((e) => e.lastAttempt == 'before'), isTrue);
    expect(overview.folders.map((f) => f.total), [0, 4]);
    expect(overview.folders.last.counts, {
      UnsyncedStatus.skipped: 2,
      UnsyncedStatus.failed: 1,
      UnsyncedStatus.pending: 1,
    });
    expect(overview.entries.firstWhere((e) => e.path == 'failed').reason,
        contains('server rejected'));
    final move = overview.entries.firstWhere((e) => e.path == 'old');
    expect(move.pathTo, 'new');
    expect(move.isDirectory, isTrue);
    expect(overview.entries.any((e) => e.path == 'private/folder'), isTrue);
    expect(overview.notices, hasLength(2));
    expect(overview.truncated, isTrue);
  });

  test('awaits mapping publication and passes only remaining global budget',
      () async {
    final admitted = Completer<void>();
    final release = Completer<void>();
    var published = false;
    final budgets = <int>[];
    final pending = buildUnsyncedOverview(
      folders: [folder('a'), folder('b')],
      maxEntries: 1,
      inspect: (_) async => {
        'items': [
          {'kind': 'conflict', 'path': 'one'}
        ],
      },
      mapFolder: (f, plan, budget, failed) async {
        budgets.add(budget);
        if (f.id == 'a') {
          admitted.complete();
          await release.future;
        }
        return mapUnsyncedFolder(f, plan, budget, failed);
      },
    ).then((value) {
      published = true;
      return value;
    });
    await admitted.future;
    expect(published, isFalse);
    expect(budgets, [1]);
    release.complete();
    final overview = await pending;
    expect(budgets, [1, 0]);
    expect(overview.total, 1);
    expect(overview.folders.map((f) => f.total), [1, 0]);
    expect(overview.counts, {UnsyncedStatus.conflict: 1});
    expect(overview.truncated, isTrue);
  });
}
