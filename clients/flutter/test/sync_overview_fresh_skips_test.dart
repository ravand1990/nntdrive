import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

SyncFolderConfig folder() => SyncFolderConfig(
      id: 'f',
      name: 'Documents',
      localPath: '/unused',
      remoteRootId: 'root',
      lastReport: {
        'skipped': [
          ['removed-link', 'old reason'],
        ],
      },
    );

void main() {
  test('current inspection skips replace historical skips with exact counts',
      () async {
    final overview = await buildUnsyncedOverview(
      folders: [folder()],
      inspect: (_) async => {
        'items': [
          {'kind': 'upload', 'path': 'ordinary.txt'},
        ],
        'skipped': [
          ['new-link', 'symbolic link skipped (follow_symlinks=false)'],
        ],
      },
    );
    expect(overview.entries.map((e) => e.path), ['ordinary.txt', 'new-link']);
    final skipped = overview.filtered(status: UnsyncedStatus.skipped).single;
    expect(skipped.reason, contains('symbolic link skipped'));
    expect(skipped.retryable, isFalse);
    expect(overview.folders.single.total, 2);
    expect(overview.counts, {
      UnsyncedStatus.localOnly: 1,
      UnsyncedStatus.skipped: 1,
    });
    expect(overview.truncated, isFalse);
  });

  test('empty or absent current skips never resurrect historical paths',
      () async {
    for (final plan in <Map<String, dynamic>>[
      {'items': [], 'skipped': []},
      {'items': []},
      {'items': [], 'skipped': 'malformed'},
    ]) {
      final overview = await buildUnsyncedOverview(
          folders: [folder()], inspect: (_) async => plan);
      expect(overview.entries, isEmpty);
      expect(overview.folders.single.total, 0);
      expect(overview.truncated, isFalse);
    }
  });

  test('inspection failure keeps a notice without historical skip evidence',
      () async {
    final overview = await buildUnsyncedOverview(
      folders: [folder()],
      inspect: (_) async => throw StateError('offline'),
    );
    expect(overview.entries, isEmpty);
    expect(overview.notices.single.message, contains('could not be compared'));
  });

  test('current skipped rows honor remaining global budget and malformed input',
      () async {
    for (final cap in [0, 1, 2]) {
      final overview = await buildUnsyncedOverview(
        folders: [folder()],
        maxEntries: cap,
        inspect: (_) async => {
          'items': [],
          'skipped': [
            null,
            [],
            [7],
            ['', 'empty'],
            ['one'],
            ['two', 9]
          ],
        },
      );
      expect(overview.total, cap);
      expect(overview.folders.single.total, cap);
      expect(overview.filtered(status: UnsyncedStatus.skipped).length, cap);
      expect(overview.truncated, cap < 2);
    }
  });

  test('blocked root replaces skips without a false truncation warning',
      () async {
    for (final cap in [0, 1, 2]) {
      final config = folder()..excluded = ['a', 'b', 'c'];
      final overview = await buildUnsyncedOverview(
        folders: [config],
        maxEntries: cap,
        inspect: (_) async => {
          'filesystem_blocked': 'permission_denied',
          'items': [],
          'skipped': [
            ['link', 'not a regular file']
          ],
        },
      );
      expect(overview.total, cap == 0 ? 0 : 1);
      expect(overview.folders.single.total, overview.total);
      expect(overview.filtered(status: UnsyncedStatus.skipped), isEmpty);
      expect(overview.truncated, cap == 0);
    }
  });
}
