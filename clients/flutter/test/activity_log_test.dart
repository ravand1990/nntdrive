import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/activity_log.dart';
import 'package:nntdrive/activity_sync.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MemoryActivityStore implements ActivityStore {
  ActivitySnapshot snapshot = const ActivitySnapshot();
  int saves = 0;

  @override
  Future<ActivitySnapshot> load() async => snapshot;

  @override
  Future<void> save(ActivitySnapshot value) async {
    snapshot = value;
    saves++;
  }
}

void main() {
  final clock = DateTime(2026, 11, 20, 12);

  ActivityLog newLog(MemoryActivityStore store, {int max = 10}) => ActivityLog(
    store: store,
    accountId: 'account-1',
    clock: () => clock,
    maxEntries: max,
  );

  test('records rows newest first and persists them', () async {
    final store = MemoryActivityStore();
    final log = newLog(store);
    await log.load();
    log.record(
      kind: ActivityKind.copied,
      folder: 'Documents',
      subject: 'a.txt',
      itemId: 'node-a',
    );
    log.record(kind: ActivityKind.deleted, folder: 'Photos', subject: 'b.png');
    await log.flush();

    expect(log.entries.map((e) => e.subject), ['b.png', 'a.txt']);
    expect(log.folderCounts, {'Photos': 1, 'Documents': 1});

    final restored = newLog(store);
    await restored.load();
    expect(restored.entries.map((e) => e.subject), ['b.png', 'a.txt']);
    expect(restored.entries.last.itemId, 'node-a');
  });

  test('filters by kind, folder and age', () async {
    final log = newLog(MemoryActivityStore());
    await log.load();
    log.record(
      kind: ActivityKind.failed,
      folder: 'Documents',
      subject: 'sync',
      reason: 'permission denied',
      at: clock.subtract(const Duration(days: 2)),
    );
    log.record(
      kind: ActivityKind.copied,
      folder: 'Documents',
      subject: 'a.txt',
    );
    log.record(
      kind: ActivityKind.downloaded,
      folder: 'Photos',
      subject: 'b.png',
    );

    expect(log.filtered(kind: ActivityKind.copied).single.subject, 'a.txt');
    expect(log.filtered(folder: 'Photos').single.subject, 'b.png');
    expect(
      log.filtered(since: clock.subtract(const Duration(days: 1))).length,
      2,
    );
    expect(
      log.filtered(kind: ActivityKind.failed).single.reason,
      'permission denied',
    );
  });

  test('notifications hide on dismissal but the entry stays', () async {
    final log = newLog(MemoryActivityStore());
    await log.load();
    log.record(
      kind: ActivityKind.failed,
      folder: 'Documents',
      subject: 'sync',
      reason: 'offline',
    );
    log.record(
      kind: ActivityKind.copied,
      folder: 'Documents',
      subject: 'a.txt',
    );
    expect(log.notificationCount, 1);

    log.dismiss(log.filtered(kind: ActivityKind.failed).single.id);
    expect(log.notificationCount, 0);
    expect(log.entries.length, 2);

    log.record(
      kind: ActivityKind.conflict,
      folder: 'Photos',
      subject: '1 item',
    );
    log.dismissAll();
    expect(log.notificationCount, 0);
  });

  test('keeps the account-scoped log bounded and prunes old rows', () async {
    final log = newLog(MemoryActivityStore(), max: 2);
    await log.load();
    for (var i = 0; i < 4; i++) {
      log.record(kind: ActivityKind.copied, folder: 'Documents', subject: '$i');
    }
    expect(log.entries.length, 2);
    expect(log.entries.map((e) => e.subject), ['3', '2']);

    log.record(
      kind: ActivityKind.copied,
      folder: 'Documents',
      subject: 'old',
      at: clock.subtract(const Duration(days: 40)),
    );
    expect(log.entries.any((e) => e.subject == 'old'), isFalse);
  });

  test('export redacts local names unless asked', () async {
    final log = newLog(MemoryActivityStore());
    await log.load();
    log.record(
      kind: ActivityKind.uploaded,
      folder: 'Documents',
      folderRootId: 'root-1',
      subject: 'budget.pdf',
      itemId: 'node-9',
      size: 4096,
    );

    final named = log.exportText(includeLocalNames: true);
    expect(named, contains('Documents'));
    expect(named, contains('budget.pdf'));
    expect(named, contains('4096 bytes'));

    final redacted = log.exportText(includeLocalNames: false);
    expect(redacted, isNot(contains('budget.pdf')));
    expect(redacted, isNot(contains('Documents')));
    expect(redacted, contains('node-9'));
    expect(redacted, contains('root-1'));
  });

  test('clear empties the feed and storage', () async {
    final store = MemoryActivityStore();
    final log = newLog(store);
    await log.load();
    log.record(
      kind: ActivityKind.copied,
      folder: 'Documents',
      subject: 'a.txt',
    );
    await log.clear();
    expect(log.entries, isEmpty);
    expect(store.snapshot.entries, isEmpty);
  });

  test(
    'preferences storage is per account and tolerates corrupt data',
    () async {
      SharedPreferences.setMockInitialValues({
        'activity.account-1': 'not json',
        'activityDismissed.account-1': jsonEncode(['gone']),
      });
      const store = PreferencesActivityStore(accountId: 'account-1');
      final snapshot = await store.load();
      expect(snapshot.entries, isEmpty);
      expect(snapshot.dismissed, {'gone'});

      await store.save(
        ActivitySnapshot(
          entries: [
            ActivityEntry(
              id: 'e1',
              at: clock,
              kind: ActivityKind.moved,
              folder: 'Photos',
              subject: 'b.png',
            ),
          ],
          dismissed: const {'e1'},
        ),
      );
      final other = await const PreferencesActivityStore(
        accountId: 'account-2',
      ).load();
      expect(other.entries, isEmpty, reason: 'accounts never share a log');

      final back = await store.load();
      expect(back.entries.single.subject, 'b.png');
      expect(back.dismissed, {'e1'});
    },
  );

  test('activity sync records failures, conflicts and counts', () async {
    final log = newLog(MemoryActivityStore());
    await log.load();
    final folder = SyncFolderConfig(
      id: 'folder-1',
      name: 'Documents',
      localPath: '/home/user/Documents',
      remoteRootId: 'root-1',
    );
    folder.lastError = 'Permission denied for /home/user/Documents';
    folder.lastReport = {
      'uploaded': 2,
      'downloaded': 1,
      'conflicts': 3,
      'errors': [
        ['/home/user/Documents/x.txt', 'integrity check failed'],
      ],
    };
    recordSyncRunActivity(log, folder, folder.lastReport);

    expect(log.filtered(kind: ActivityKind.failed).single.subject, 'sync');
    expect(
      log.filtered(kind: ActivityKind.failed).single.reason,
      'Permission denied for /home/user/Documents',
    );
    expect(log.filtered(kind: ActivityKind.conflict).single.subject, '3 items');
    expect(log.filtered(kind: ActivityKind.uploaded).single.subject, '2 items');
    expect(
      log.filtered(kind: ActivityKind.downloaded).single.subject,
      '1 item',
    );
    expect(log.entries.every((e) => e.folderRootId == 'root-1'), isTrue);
  });

  test('activity sync records a failed run without a report', () async {
    final log = newLog(MemoryActivityStore());
    await log.load();
    final folder = SyncFolderConfig(
      id: 'folder-1',
      name: 'Photos',
      localPath: '/home/user/Photos',
      remoteRootId: 'root-2',
    );
    folder.lastError =
        'Sync failed. Check storage access and server connectivity, then retry.';
    recordSyncRunActivity(log, folder, null);
    expect(log.entries.length, 1);
    expect(log.entries.single.kind, ActivityKind.failed);
    expect(log.entries.single.reason, startsWith('Sync failed.'));
  });

  test('formats row time in local terms', () {
    expect(formatActivityTime(DateTime(2026, 11, 20, 9, 5)), '20 Nov 09:05');
  });
}
