import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

SyncFolderConfig makeFolder(
  String id,
  String name, {
  bool enabled = true,
  Map<String, dynamic>? report,
  List<String> excluded = const [],
  bool storageAccessRequired = false,
  String? lastSync,
}) {
  final folder = SyncFolderConfig(
    id: id,
    name: name,
    localPath: '/tmp/$id',
    remoteRootId: 'root-$id',
    enabled: enabled,
    lastReport: report,
    excluded: excluded,
    lastSync: lastSync,
  );
  folder.storageAccessRequired = storageAccessRequired;
  return folder;
}

Map<String, dynamic> plan(
  List<Map<String, dynamic>> items, {
  bool folderMovesPending = false,
  bool journalAvailable = true,
  bool truncated = false,
  List<List<String>> caseCollisions = const [],
}) =>
    {
      'items': items,
      'folder_moves_pending': folderMovesPending,
      'journal_available': journalAvailable,
      'truncated': truncated,
      'case_collisions': caseCollisions,
    };

Map<String, dynamic> item(String kind, String path,
        {String? pathTo, int? size, bool isDir = false}) =>
    {
      'kind': kind,
      'path': path,
      if (pathTo != null) 'path_to': pathTo,
      if (size != null) 'size': size,
      'is_dir': isDir,
    };

void main() {
  test('maps every plan kind to a user status with a reason', () async {
    final folder = makeFolder('f1', 'Documents');
    final overview = await buildUnsyncedOverview(
      folders: [folder],
      inspect: (_) async => plan([
        item('upload', 'notes.txt', size: 12),
        item('download', 'theirs.txt'),
        item('create_remote_dir', 'local-folder', isDir: true),
        item('create_local_dir', 'remote-folder', isDir: true),
        item('delete_local', 'gone-locally.txt'),
        item('delete_remote', 'gone-remotely.txt'),
        item('rename_local', 'old.txt', pathTo: 'new.txt'),
        item('adopt_revision', 'same.txt', size: 4),
        item('conflict', 'both.txt', pathTo: 'both (conflict laptop t).txt'),
      ]),
    );

    final byPath = {for (final entry in overview.entries) entry.path: entry};
    expect(byPath['notes.txt']!.status, UnsyncedStatus.localOnly);
    expect(byPath['notes.txt']!.reason, contains('Not uploaded'));
    expect(byPath['theirs.txt']!.status, UnsyncedStatus.cloudOnly);
    expect(byPath['local-folder']!.status, UnsyncedStatus.localOnly);
    expect(byPath['local-folder']!.isDirectory, isTrue);
    expect(byPath['remote-folder']!.status, UnsyncedStatus.cloudOnly);
    expect(byPath['gone-locally.txt']!.status, UnsyncedStatus.pending);
    expect(byPath['gone-remotely.txt']!.status, UnsyncedStatus.pending);
    expect(byPath['old.txt']!.status, UnsyncedStatus.pending);
    expect(byPath['old.txt']!.pathTo, 'new.txt');
    expect(byPath['same.txt']!.status, UnsyncedStatus.pending);
    expect(byPath['both.txt']!.status, UnsyncedStatus.conflict);
    expect(byPath['both.txt']!.pathTo, contains('conflict'));
    expect(overview.total, 9);
    expect(overview.notices, isEmpty);
  });

  test('keeps folder identity separate for the same relative path', () async {
    final overview = await buildUnsyncedOverview(
      folders: [makeFolder('a', 'Alpha'), makeFolder('b', 'Beta')],
      inspect: (folder) async => plan([item('upload', 'shared.txt')]),
    );
    expect(overview.entries, hasLength(2));
    expect(overview.folders.map((f) => f.folderName), ['Alpha', 'Beta']);
    expect(overview.filtered(folderId: 'b').single.folderName, 'Beta');
  });

  test('reports a path that failed in the last attempt as failed', () async {
    final folder = makeFolder('f1', 'Documents', report: {
      'item_errors': [
        {
          'paths': ['busy.txt'],
          'operation': 'upload',
          'code': 'io',
        }
      ],
    });
    final overview = await buildUnsyncedOverview(
      folders: [folder],
      inspect: (_) async => plan([item('upload', 'busy.txt')]),
    );
    final entry = overview.entries.single;
    expect(entry.status, UnsyncedStatus.failed);
    expect(entry.reason, contains('Reading or writing'));
  });

  test('lists selective-sync exclusions and engine skips as skipped', () async {
    final folder = makeFolder('f1', 'Documents',
        excluded: ['private'],
        report: {
          'skipped': [
            ['link', 'not a regular file']
          ],
        });
    final overview = await buildUnsyncedOverview(
      folders: [folder],
      inspect: (_) async => plan([]),
    );
    final byPath = {for (final entry in overview.entries) entry.path: entry};
    expect(byPath['private']!.status, UnsyncedStatus.skipped);
    expect(byPath['private']!.retryable, isFalse);
    expect(byPath['link']!.status, UnsyncedStatus.skipped);
    expect(byPath['link']!.reason, contains('not a regular file'));
  });

  test('marks case-only collisions as blocked', () async {
    final overview = await buildUnsyncedOverview(
      folders: [makeFolder('f1', 'Documents')],
      inspect: (_) async => plan(
        [item('upload', 'a.txt'), item('upload', 'A.txt')],
        caseCollisions: [
          ['a.txt', 'A.txt']
        ],
      ),
    );
    expect(
        overview.entries.every((e) => e.status == UnsyncedStatus.blocked), isTrue);
  });

  test('a folder without storage access is blocked, never silently in sync',
      () async {
    var inspected = false;
    final overview = await buildUnsyncedOverview(
      folders: [
        makeFolder('f1', 'Shared', storageAccessRequired: true, lastSync: 'now')
      ],
      inspect: (_) async {
        inspected = true;
        return plan([]);
      },
    );
    expect(inspected, isFalse);
    final entry = overview.entries.single;
    expect(entry.status, UnsyncedStatus.blocked);
    expect(entry.retryable, isFalse);
    expect(entry.reason, contains('Storage access'));
  });

  test('an inspection failure is a notice, not an empty in-sync claim', () async {
    final overview = await buildUnsyncedOverview(
      folders: [makeFolder('f1', 'Documents')],
      inspect: (_) async => throw StateError('offline'),
    );
    expect(overview.entries, isEmpty);
    expect(overview.notices.single.message, contains('could not be compared'));
  });

  test('a pending folder move or missing journal is explained', () async {
    final overview = await buildUnsyncedOverview(
      folders: [makeFolder('f1', 'Documents')],
      inspect: (_) async =>
          plan([], folderMovesPending: true, journalAvailable: false),
    );
    expect(overview.notices, hasLength(2));
    expect(overview.notices.map((n) => n.message).join(),
        contains('folder move is still pending'));
    expect(overview.notices.map((n) => n.message).join(),
        contains('No completed sync'));
  });

  test('counts, filtering and truncation stay consistent', () async {
    final overview = await buildUnsyncedOverview(
      folders: [makeFolder('f1', 'Documents')],
      inspect: (_) async => plan([
        item('upload', 'a.txt'),
        item('upload', 'b.txt'),
        item('download', 'c.txt'),
      ]),
      maxEntries: 2,
    );
    expect(overview.truncated, isTrue);
    expect(overview.total, 2);
    expect(overview.counts[UnsyncedStatus.localOnly], 2);
    expect(overview.filtered(status: UnsyncedStatus.cloudOnly), isEmpty);
  });
}
