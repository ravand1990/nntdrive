import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
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
  testWidgets('mapped filesystem block is a filterable root with access and refresh',
      (tester) async {
    final grants = <String>[];
    var blocked = true;
    final folder = SyncFolderConfig(
      id: 'root', name: 'Documents', localPath: '/private/root', remoteRootId: 'remote',
    );
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () => buildUnsyncedOverview(
        folders: [folder],
        inspect: (_) async => blocked
            ? {'filesystem_blocked': 'permission_denied', 'items': []}
            : {'items': [], 'journal_available': true},
      ),
      onSyncFolder: (_) async => fail('a blocked root must not retry a partial plan'),
      onGrantAccess: (id) async {
        grants.add(id);
        blocked = false;
        return true;
      },
    )));
    // Real worker messages need real event turns; fake frame settling alone
    // cannot deliver an isolate result.
    for (var i = 0; i < 100 && find.text('Blocked · Documents').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.text('Everything is in sync.'), findsNothing);
    expect(find.widgetWithText(FilterChip, 'Blocked (1)'), findsOneWidget);
    expect(find.text('Blocked · Documents'), findsOneWidget);
    expect(find.textContaining('Check storage permissions'), findsOneWidget);
    expect(find.byTooltip('Sync Documents now'), findsNothing);
    expect(find.textContaining('/private/root'), findsNothing);
    await tester.tap(find.widgetWithText(FilterChip, 'Blocked (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Documents').last);
    await tester.pumpAndSettle();
    expect(find.text('Grant access'), findsOneWidget);
    expect(find.text('Sync now'), findsNothing);
    await tester.tap(find.text('Grant access'));
    for (var i = 0; i < 100 && find.text('Everything is in sync.').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(grants, ['root']);
    expect(find.text('Blocked · Documents'), findsNothing);
    expect(find.text('Everything is in sync.'), findsOneWidget);
  });

  testWidgets('mapped current conflict keeps Resolve after a historical failure',
      (tester) async {
    final folder = SyncFolderConfig(
      id: 'f1', name: 'Documents', localPath: '/private/root', remoteRootId: 'remote',
      lastReport: {
        'item_errors': [
          {'paths': ['both.txt'], 'operation': 'upload', 'code': 'io'},
        ],
      },
    );
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () => buildUnsyncedOverview(
        folders: [folder],
        inspect: (_) async => {
          'items': [
            {'kind': 'conflict', 'path': 'both.txt', 'path_to': 'both (conflict 1).txt'},
          ],
        },
      ),
      onSyncFolder: (_) async {},
      onResolveConflict: (_, __, ___) async {},
    )));
    for (var i = 0; i < 100 && find.text('both.txt').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilterChip, 'Conflict (1)'), findsOneWidget);
    expect(find.widgetWithText(FilterChip, 'Failed (1)'), findsNothing);
    await tester.tap(find.text('both.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflict'), findsOneWidget);
    expect(find.textContaining('Choose keep mine'), findsWidgets);
  });

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

  testWidgets('retry syncs the row folder and reloads the plan by itself',
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
    // The list reloads after the action; no manual refresh is needed.
    expect(loads, 2);

    await tester.tap(find.byTooltip('Check again'));
    await tester.pumpAndSettle();
    expect(loads, 3);
  });

  testWidgets('a finished sync round reloads the plan, but not mid-round',
      (tester) async {
    final changes = ChangeNotifier();
    var busy = true;
    var loads = 0;
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async {
        loads++;
        return overviewOf([entry(UnsyncedStatus.cloudOnly, 'cloud.txt')]);
      },
      onSyncFolder: (_) async {},
      watch: changes,
      isBusy: () => busy,
    )));
    await tester.pumpAndSettle();
    expect(loads, 1);

    changes.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(loads, 1, reason: 'a running sync does not reload the plan');

    busy = false;
    changes.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(loads, 2);
  });

  testWidgets('a conflict is resolved from its row and the list reloads',
      (tester) async {
    final calls = <String>[];
    var loads = 0;
    const copy = 'notes (conflict 2026-11-13).txt';
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async {
        loads++;
        return overviewOf([
          entry(UnsyncedStatus.conflict, copy, reason: 'Both sides changed.'),
        ]);
      },
      onSyncFolder: (_) async {},
      onResolveConflict: (folderId, copyPath, choice) async =>
          calls.add('$folderId|$copyPath|$choice'),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text(copy));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resolve conflict'));
    await tester.pumpAndSettle();
    // The dialog names both sides before anything is applied.
    expect(find.textContaining('notes.txt'), findsOneWidget);
    await tester.tap(find.text('Keep theirs'));
    await tester.pumpAndSettle();

    expect(calls, ['f1|$copy|theirs']);
    expect(loads, 2);
  });

  testWidgets('a failed conflict resolution is reported and keeps the list',
      (tester) async {
    var loads = 0;
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async {
        loads++;
        return overviewOf([entry(UnsyncedStatus.conflict, 'a (conflict 1).txt')]);
      },
      onSyncFolder: (_) async {},
      onResolveConflict: (_, __, ___) async => throw StateError('nope'),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('a (conflict 1).txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Resolve conflict'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep both'));
    await tester.pumpAndSettle();

    expect(find.text('That action did not finish. Try again.'), findsOneWidget);
    expect(loads, 2);
    expect(find.text('a (conflict 1).txt'), findsOneWidget);
  });

  testWidgets('no conflict action is offered without a resolver',
      (tester) async {
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async =>
          overviewOf([entry(UnsyncedStatus.conflict, 'b (conflict 1).txt')]),
      onSyncFolder: (_) async {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('b (conflict 1).txt'));
    await tester.pumpAndSettle();
    expect(find.text('Resolve conflict'), findsNothing);
  });

  testWidgets('local copy reveal uses the exact row and reloads afterwards',
      (tester) async {
    final item = entry(UnsyncedStatus.localOnly, 'nested/local.txt');
    var loads = 0;
    final inspected = <UnsyncedEntry>[];
    final revealed = <UnsyncedEntry>[];
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async {
        loads++;
        return overviewOf([item]);
      },
      onSyncFolder: (_) async => fail('Reveal must not sync'),
      canRevealLocal: (entry) async {
        inspected.add(entry);
        return true;
      },
      onRevealLocal: (entry) async => revealed.add(entry),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('local.txt'));
    await tester.pumpAndSettle();
    expect(inspected, [same(item)]);
    await tester.tap(find.text('Show local copy'));
    await tester.pumpAndSettle();
    expect(revealed, [same(item)]);
    expect(loads, 2);
  });

  testWidgets('missing local copy disables reveal with a text explanation',
      (tester) async {
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async => overviewOf([entry(UnsyncedStatus.cloudOnly, 'cloud.txt')]),
      onSyncFolder: (_) async {},
      canRevealLocal: (_) async => false,
      onRevealLocal: (_) async => fail('Missing copy must not launch'),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cloud.txt'));
    await tester.pumpAndSettle();
    final button = tester.widget<OutlinedButton>(find.widgetWithText(
        OutlinedButton, 'Show local copy'));
    expect(button.onPressed, isNull);
    expect(find.textContaining('No safe local copy'), findsOneWidget);
  });

  testWidgets('stale reveal failure is redacted and reloads the list',
      (tester) async {
    var loads = 0;
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async {
        loads++;
        return overviewOf([entry(UnsyncedStatus.failed, 'file.txt')]);
      },
      onSyncFolder: (_) async {},
      canRevealLocal: (_) async => true,
      onRevealLocal: (_) async => throw StateError('PRIVATE PATH'),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('file.txt'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show local copy'));
    await tester.pumpAndSettle();
    expect(find.text('That action did not finish. Try again.'), findsOneWidget);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(loads, 2);
  });

  testWidgets('unsupported platforms offer no local reveal action',
      (tester) async {
    await tester.pumpWidget(host(SyncOverviewPage(
      load: () async => overviewOf([entry(UnsyncedStatus.localOnly, 'local.txt')]),
      onSyncFolder: (_) async {},
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('local.txt'));
    await tester.pumpAndSettle();
    expect(find.text('Show local copy'), findsNothing);
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
