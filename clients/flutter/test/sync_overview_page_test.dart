import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:nntdrive/sync_overview_page.dart';

UnsyncedEntry entry(UnsyncedStatus status, String path,
        {String folder = 'Documents',
        String folderId = 'f1',
        String reason = 'reason',
        int? size,
        String? pathTo,
        bool retryable = true}) =>
    UnsyncedEntry(
      status: status,
      folderId: folderId,
      folderName: folder,
      path: path,
      reason: reason,
      size: size,
      pathTo: pathTo,
      retryable: retryable,
    );

UnsyncedOverview overviewOf(List<UnsyncedEntry> entries,
        {List<UnsyncedNotice> notices = const []}) =>
    UnsyncedOverview(
      entries: entries,
      folders: const [],
      notices: notices,
      inspectedAt: DateTime(2026, 11, 13, 12),
    );

Widget host(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('shows the total, status text and filters by status',
      (tester) async {
    final overview = overviewOf([
      entry(UnsyncedStatus.localOnly, 'a.txt', size: 2048),
      entry(UnsyncedStatus.localOnly, 'b.txt'),
      entry(UnsyncedStatus.failed, 'c.txt', reason: 'The server failed.'),
    ]);
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async => overview,
      onSyncFolder: (_) async {},
    )));
    await tester.pumpAndSettle();

    expect(find.text('3 items are not fully in sync.'), findsOneWidget);
    expect(find.text('a.txt'), findsOneWidget);
    expect(find.text('c.txt'), findsOneWidget);
    expect(find.textContaining('Local only'), findsWidgets);
    expect(find.textContaining('Failed'), findsWidgets);
    // Size is shown but never the absolute local path.
    expect(find.text('2.0 KB'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Failed (1)'));
    await tester.pumpAndSettle();
    expect(find.text('c.txt'), findsOneWidget);
    expect(find.text('a.txt'), findsNothing);
    expect(find.text('The server failed.'), findsOneWidget);
  });

  testWidgets('states clearly when everything is in sync', (tester) async {
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async => overviewOf(const []),
      onSyncFolder: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Everything is in sync.'), findsOneWidget);
    expect(find.text('Nothing is waiting for sync.'), findsOneWidget);
  });

  testWidgets('retry syncs the row folder and refresh reloads the plan',
      (tester) async {
    final synced = <String>[];
    var loads = 0;
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async {
        loads++;
        return overviewOf([entry(UnsyncedStatus.cloudOnly, 'cloud.txt')]);
      },
      onSyncFolder: (folderId) async => synced.add(folderId),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sync Documents now'));
    await tester.pumpAndSettle();
    expect(synced, ['f1']);

    await tester.tap(find.byTooltip('Check again'));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('folder-level problems are visible, not an empty list',
      (tester) async {
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async => overviewOf(
        [entry(UnsyncedStatus.blocked, '', reason: 'Storage access is needed.')],
        notices: const [UnsyncedNotice('Shared', 'Folder could not be compared.')],
      ),
      onSyncFolder: (_) async {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('Folder could not be compared.'), findsOneWidget);
    expect(find.textContaining('Storage access is needed.'), findsOneWidget);
  });
}
