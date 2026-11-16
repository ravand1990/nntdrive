import 'dart:async';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

// A sendable entry that makes a caller-isolate comparator fail deterministically.
class WorkerOnlyEntry extends UnsyncedEntry {
  WorkerOnlyEntry(this.caller, String path)
      : super(
          status: UnsyncedStatus.localOnly,
          folderId: 'f',
          folderName: 'Folder',
          path: path,
          reason: 'Local only',
        );

  final SendPort caller;

  @override
  String get folderName {
    if (Isolate.current.controlPort == caller) {
      throw StateError('Ordering ran on the caller isolate');
    }
    return 'Folder';
  }
}

SyncFolderConfig folder(String id, String name) => SyncFolderConfig(
      id: id,
      name: name,
      localPath: '/unused',
      remoteRootId: id,
    );

void main() {
  test('ordering comparator runs off the caller isolate', () async {
    final entries = [
      WorkerOnlyEntry(Isolate.current.controlPort, 'z'),
      WorkerOnlyEntry(Isolate.current.controlPort, 'a'),
    ];
    final ordered = await orderUnsyncedEntries(entries);
    expect(ordered.map((e) => e.path), ['a', 'z']);
    expect(entries.map((e) => e.path), ['z', 'a']);
  });

  test('builder dispatches once without pre-sorting or capturing inspector',
      () async {
    // ReceivePort is deliberately unsendable. The inspector must never cross
    // into the ordering worker via the builder's lexical context.
    final port = ReceivePort();
    addTearDown(port.close);
    var dispatched = 0;
    final overview = await buildUnsyncedOverview(
      folders: [folder('b', 'Beta'), folder('a', 'Alpha')],
      inspect: (f) async {
        expect(port.sendPort, isA<SendPort>());
        return {
          'items': [
            {'kind': 'upload', 'path': 'z.txt', 'size': 9},
            {'kind': 'download', 'path': 'c.txt', 'size': 3},
            {'kind': 'upload', 'path': 'a.txt', 'size': 1},
          ],
        };
      },
      orderEntries: (entries) {
        dispatched++;
        expect(entries.map((e) => '${e.folderId}/${e.path}'), [
          'b/z.txt',
          'b/c.txt',
          'b/a.txt',
          'a/z.txt',
          'a/c.txt',
          'a/a.txt',
        ]);
        return orderUnsyncedEntries(entries);
      },
    );
    expect(dispatched, 1);
    expect(overview.entries.map((e) => '${e.folderId}/${e.path}'), [
      'a/c.txt',
      'a/a.txt',
      'a/z.txt',
      'b/c.txt',
      'b/a.txt',
      'b/z.txt',
    ]);
    expect(overview.folders.map((f) => f.total), [3, 3]);
    expect(overview.counts, {
      UnsyncedStatus.localOnly: 4,
      UnsyncedStatus.cloudOnly: 2,
    });
    expect(
        overview
            .filtered(folderId: 'a', status: UnsyncedStatus.localOnly)
            .map((e) => e.size),
        [1, 9]);
  });

  test('builder awaits ordering completion before publishing a result',
      () async {
    final admitted = Completer<void>();
    final release = Completer<void>();
    var published = false;
    final result = buildUnsyncedOverview(
      folders: [folder('a', 'Alpha')],
      inspect: (_) async => {
        'items': [
          {'kind': 'upload', 'path': 'a'}
        ]
      },
      orderEntries: (entries) async {
        admitted.complete();
        await release.future;
        return orderUnsyncedEntries(entries);
      },
    ).then((value) {
      published = true;
      return value;
    });
    await admitted.future;
    expect(published, isFalse);
    release.complete();
    expect((await result).total, 1);
  });

  test('large bounded builder yields while worker ordering is pending',
      () async {
    var eventTurn = false;
    final overview = await buildUnsyncedOverview(
      folders: [folder('a', 'Alpha')],
      inspect: (_) async {
        Timer.run(() => eventTurn = true);
        return {
          'items': List.generate(
              20001,
              (i) => {
                    'kind': 'upload',
                    'path': '${20001 - i}'.padLeft(6, '0'),
                  }),
        };
      },
    );
    expect(eventTurn, isTrue);
    expect(overview.total, 20000);
    expect(overview.truncated, isTrue);
    expect(overview.entries.first.path, '000002');
    expect(overview.entries.last.path, '020001');
    expect(overview.folders.single.total, overview.total);
    expect(overview.counts[UnsyncedStatus.localOnly], overview.total);
  });

  test('empty and single-entry ordering preserves all metadata', () async {
    expect(await orderUnsyncedEntries([]), isEmpty);
    const entry = UnsyncedEntry(
      status: UnsyncedStatus.pending,
      folderId: 'f',
      folderName: 'Folder',
      path: 'old',
      pathTo: 'new',
      reason: 'Move pending',
      size: 12,
      isDirectory: true,
      lastAttempt: '2026-11-16T12:00:00Z',
      retryable: false,
    );
    final copied = (await orderUnsyncedEntries([entry])).single;
    expect(copied.status, entry.status);
    expect(copied.folderId, entry.folderId);
    expect(copied.folderName, entry.folderName);
    expect(copied.path, entry.path);
    expect(copied.pathTo, entry.pathTo);
    expect(copied.reason, entry.reason);
    expect(copied.size, entry.size);
    expect(copied.isDirectory, entry.isDirectory);
    expect(copied.lastAttempt, entry.lastAttempt);
    expect(copied.retryable, entry.retryable);
  });
}
