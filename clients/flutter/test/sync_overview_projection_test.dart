import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

UnsyncedEntry row(UnsyncedStatus status, String folder, String path) =>
    UnsyncedEntry(
      status: status,
      folderId: folder,
      folderName: folder,
      path: path,
      reason: 'reason',
    );

// Changes after snapshot preparation expose any later full-entry scans.
class SealedEntry extends UnsyncedEntry {
  SealedEntry()
      : super(
          status: UnsyncedStatus.pending,
          folderId: 'f',
          folderName: 'Folder',
          path: 'one',
          reason: 'reason',
        );
  bool sealed = false;

  @override
  UnsyncedStatus get status {
    if (sealed) throw StateError('Snapshot status was rescanned');
    return UnsyncedStatus.pending;
  }

  @override
  String get folderId {
    if (sealed) throw StateError('Snapshot folder was rescanned');
    return 'f';
  }
}

UnsyncedOverview snapshot(List<UnsyncedEntry> entries) => UnsyncedOverview(
      entries: entries,
      folders: const [],
      notices: const [],
      inspectedAt: DateTime(2026),
    );

class WorkerOnlyEntry extends UnsyncedEntry {
  WorkerOnlyEntry(this.caller, String path)
      : super(
          status: UnsyncedStatus.localOnly,
          folderId: 'f',
          folderName: 'Folder',
          path: path,
          reason: 'reason',
        );
  final SendPort caller;

  void checkWorker() {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Projection scanned entries on caller');
    }
  }

  @override
  UnsyncedStatus get status {
    checkWorker();
    return UnsyncedStatus.localOnly;
  }

  @override
  String get folderId {
    checkWorker();
    return 'f';
  }
}

SyncFolderConfig folder(String id) => SyncFolderConfig(
      id: id,
      name: id,
      localPath: '/unused',
      remoteRootId: id,
    );

void main() {
  test('snapshot reads counts and every filter without rescanning entries', () {
    final entry = SealedEntry();
    final overview = snapshot([entry]);
    entry.sealed = true;
    for (var repeat = 0; repeat < 3; repeat++) {
      expect(overview.counts, {UnsyncedStatus.pending: 1});
      for (final status in <UnsyncedStatus?>[null, ...UnsyncedStatus.values]) {
        for (final folder in <String?>[null, 'f', 'unknown', '']) {
          expect(
            overview.filtered(status: status, folderId: folder).length,
            (status == null || status == UnsyncedStatus.pending) &&
                    (folder == null || folder == 'f')
                ? 1
                : 0,
          );
        }
      }
    }
  });

  test('snapshot owns immutable entries counts and filter results', () {
    final input = [row(UnsyncedStatus.localOnly, 'a', 'one')];
    final overview = snapshot(input);
    input.clear();
    expect(overview.total, 1);
    expect(() => overview.entries.clear(), throwsUnsupportedError);
    expect(() => overview.counts.clear(), throwsUnsupportedError);
    expect(() => overview.filtered().clear(), throwsUnsupportedError);
    expect(
        () => overview.filtered(folderId: 'a').clear(), throwsUnsupportedError);
    expect(() => overview.filtered(status: UnsyncedStatus.localOnly).clear(),
        throwsUnsupportedError);
    expect(
        () => overview
            .filtered(status: UnsyncedStatus.localOnly, folderId: 'a')
            .clear(),
        throwsUnsupportedError);
  });

  test('all status and folder combinations retain input order and identity',
      () async {
    final entries = [
      for (final folder in ['b', 'a', ''])
        for (final status in UnsyncedStatus.values.reversed)
          for (final path in ['z', 'a']) row(status, folder, path),
    ];
    final overview = snapshot(entries);
    final projection = await projectUnsyncedEntries(entries);
    for (final status in <UnsyncedStatus?>[null, ...UnsyncedStatus.values]) {
      for (final folder in <String?>[null, 'b', 'a', '', 'unknown']) {
        final expected = entries.where((e) =>
            (status == null || e.status == status) &&
            (folder == null || e.folderId == folder));
        expect(overview.filtered(status: status, folderId: folder),
            orderedEquals(expected));
        expect(
            projection
                .filtered(status: status, folderId: folder)
                .map((e) => '${e.folderId}/${e.status}/${e.path}'),
            orderedEquals(
                expected.map((e) => '${e.folderId}/${e.status}/${e.path}')));
        expect(
            () => projection.filtered(status: status, folderId: folder).clear(),
            throwsUnsupportedError);
      }
    }
    expect(overview.counts,
        {for (final status in UnsyncedStatus.values) status: 6});
    final empty = snapshot([]);
    expect(empty.counts, isEmpty);
    expect(empty.filtered(folderId: 'unknown'), isEmpty);
    final emptyProjection = await projectUnsyncedEntries([]);
    expect(emptyProjection.counts, isEmpty);
    expect(emptyProjection.filtered(status: UnsyncedStatus.blocked), isEmpty);
    expect(() => emptyProjection.entries.clear(), throwsUnsupportedError);
    expect(() => projection.counts.clear(), throwsUnsupportedError);
  });

  test('projection getters run on a worker even for a single row', () async {
    final projection = await projectUnsyncedEntries([
      WorkerOnlyEntry(Isolate.current.controlPort, 'one'),
    ]);
    expect(projection.counts, {UnsyncedStatus.localOnly: 1});
    expect(projection.filtered(folderId: 'f').single.path, 'one');
    expect(projection.filtered(status: UnsyncedStatus.pending), isEmpty);
  });

  test('single-row projection yields a real event turn', () async {
    var eventTurn = false;
    Timer.run(() => eventTurn = true);
    final projection = await projectUnsyncedEntries([
      row(UnsyncedStatus.localOnly, 'f', 'one'),
    ]);
    expect(eventTurn, isTrue);
    expect(projection.entries.single.path, 'one');
  });

  test('default builder projection never scans ordered rows on caller',
      () async {
    final port = ReceivePort();
    addTearDown(port.close);
    var orderingCalls = 0;
    final overview = await buildUnsyncedOverview(
      folders: [folder('f')],
      inspect: (_) async {
        expect(port.sendPort, isA<SendPort>());
        return {
          'items': [
            {'kind': 'upload', 'path': 'z'},
            {'kind': 'upload', 'path': 'a'},
          ]
        };
      },
      orderEntries: (entries) async {
        orderingCalls++;
        final ordered = await orderUnsyncedEntries(entries);
        return [
          for (final e in ordered)
            WorkerOnlyEntry(Isolate.current.controlPort, e.path)
        ];
      },
    );
    expect(orderingCalls, 1);
    for (var i = 0; i < 3; i++) {
      expect(overview.counts, {UnsyncedStatus.localOnly: 2});
      expect(
          overview
              .filtered(folderId: 'f', status: UnsyncedStatus.localOnly)
              .map((e) => e.path),
          ['a', 'z']);
      expect(overview.filtered(folderId: 'unknown'), isEmpty);
    }
  });

  test('builder projects once after ordering and awaits publication', () async {
    final admitted = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    var published = false;
    var ordered = false;
    final pending = buildUnsyncedOverview(
      folders: [folder('b'), folder('a')],
      inspect: (_) async => {
        'items': [
          {'kind': 'upload', 'path': 'z'},
          {'kind': 'download', 'path': 'a'},
        ]
      },
      orderEntries: (entries) async {
        final result = await orderUnsyncedEntries(entries);
        ordered = true;
        return result;
      },
      projectEntries: (entries) async {
        calls++;
        expect(ordered, isTrue);
        expect(entries.map((e) => '${e.folderId}/${e.path}'),
            ['a/a', 'a/z', 'b/a', 'b/z']);
        admitted.complete();
        await release.future;
        return projectUnsyncedEntries(entries);
      },
    ).then((value) {
      published = true;
      return value;
    });
    await admitted.future;
    expect(published, isFalse);
    release.complete();
    final overview = await pending;
    expect(calls, 1);
    final counts = overview.counts;
    final filtered = overview.filtered(folderId: 'a');
    expect(identical(overview.counts, counts), isTrue);
    expect(identical(overview.filtered(folderId: 'a'), filtered), isTrue);
    expect(calls, 1);
  });

  for (final cap in [0, 1, 2, 3, 4, 20000]) {
    test(
        'projection counts and filters describe only retained rows at cap $cap',
        () async {
      final blocked = folder('blocked')..storageAccessRequired = true;
      final overview = await buildUnsyncedOverview(
        folders: [folder('a'), blocked],
        maxEntries: cap,
        inspect: (_) async => {
          'items': [
            {'kind': 'upload', 'path': 'z'},
            {'kind': 'download', 'path': 'a'},
            {'kind': 'conflict', 'path': 'same'},
          ]
        },
      );
      expect(overview.total, cap < 4 ? cap : 4);
      expect(overview.truncated, cap < 4);
      expect(
          overview.counts.values.fold<int>(0, (a, b) => a + b), overview.total);
      for (final summary in overview.folders) {
        final retained = overview.filtered(folderId: summary.folderId);
        expect(retained.length, summary.total);
        for (final status in UnsyncedStatus.values) {
          expect(
              overview
                  .filtered(folderId: summary.folderId, status: status)
                  .map((e) => e.path),
              retained.where((e) => e.status == status).map((e) => e.path));
        }
        expect(() => summary.counts.clear(), throwsUnsupportedError);
      }
      expect(() => overview.folders.clear(), throwsUnsupportedError);
      expect(() => overview.notices.clear(), throwsUnsupportedError);
      expect(overview.filtered(folderId: 'unknown'), isEmpty);
    });
  }
}
