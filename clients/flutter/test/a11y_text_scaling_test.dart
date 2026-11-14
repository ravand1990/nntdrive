import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/rename_dialog.dart';
import 'package:nntdrive/search_page.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:nntdrive/sync_widgets.dart';

/// Every page below is also used on phones, so the layout is exercised at a
/// phone width with the text scaled to the system accessibility maximum we
/// support. A doubled scale must reflow, never overflow.
const _phone = Size(400, 900);

Widget _scaled(Widget home) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: home,
    );

SyncController _sync() => SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async => const AccountRootsResult([]),
    );

void _surface(WidgetTester tester, {Size size = _phone}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The sync page is one long ListView; a tall surface keeps its later cards
/// built so their layout is checked too.
void _tall(WidgetTester tester) => _surface(tester, size: const Size(400, 3000));

AccountSearch _index() => AccountSearch(
      handle: 1,
      operations: SessionOperations(),
      list: (p) async => p == null
          ? [RemoteFile('d', null, 'opaque-folder', true, 0, false, 1, null)]
          : [RemoteFile('f', 'd', 'opaque-file', false, 42, true, 1, null)],
      decrypt: (f) => f.isDir ? 'Private folder' : 'Report.pdf',
      authorize: () {},
    );

/// pumpAndSettle only drains fake frames, not real isolate messages, and the
/// page rebuilds the index on entry. Wait for the rebuild to finish and elapse
/// fake time so its zero-duration yield timers fire before the tree is disposed.
Future<void> _drainRebuild(WidgetTester tester, AccountSearch index) async {
  for (var i = 0; i < 600; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 20));
    final quiet = !index.building &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.text('Report.pdf').evaluate().isNotEmpty;
    if (quiet && i > 5) break;
  }
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  testWidgets('sync folders fit 200% text on a phone', (tester) async {
    _tall(tester);
    final sync = _sync();
    addTearDown(sync.dispose);
    sync.folders.addAll([
      SyncFolderConfig(
        id: 'a',
        name: 'Documents',
        localPath: '/home/tester/Documents with a long path',
        remoteRootId: 'r1',
        lastSync: '2026-11-14T10:00:00Z',
        lastReport: const {'uploaded': 3, 'downloaded': 1, 'conflicts': 0},
      )..conflictFiles = ['report (conflict dev).txt'],
      SyncFolderConfig(
        id: 'b',
        name: 'Photos',
        localPath: '/home/tester/Pictures',
        remoteRootId: 'r2',
        lastError:
            'Some files could not be synchronized because the path is too long.',
        lastReport: const {'uploaded': 0, 'downloaded': 0},
      )..progress = const {
          'path': 'very/long/path/that/keeps/going/file-with-a-long-name.jpg',
          'direction': 'upload',
          'bytes': 1234567,
          'total': 9876543,
          'complete': false,
        },
    ]);
    await tester.pumpWidget(_scaled(SyncPage(controller: sync)));
    await tester.pumpAndSettle();

    // The page is one long lazy list; walk it so every card is laid out.
    for (var i = 0; i < 20; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pump();
    }
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a doubled text size must not overflow the sync cards');
    expect(find.textContaining('Base folder'), findsOneWidget);
    expect(find.textContaining('Additional folder'), findsOneWidget);
    expect(find.textContaining('could not be synchronized'), findsOneWidget);
  });

  testWidgets('the empty sync page fits 200% text on a phone', (tester) async {
    _tall(tester);
    final sync = _sync();
    addTearDown(sync.dispose);
    await tester.pumpWidget(_scaled(SyncPage(controller: sync)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Choose your base folder'), findsOneWidget);
    expect(find.text('Select base folder'), findsOneWidget);
  });

  testWidgets('search filters and results fit 200% text on a phone',
      (tester) async {
    _surface(tester);
    final index = _index();
    addTearDown(index.dispose);
    await tester.runAsync(() => index.rebuild());
    await tester.pumpWidget(_scaled(AccountSearchPage(index: index)));
    await _drainRebuild(tester, index);

    expect(tester.takeException(), isNull,
        reason: 'the filter row must reflow instead of overflowing at 200%');
    expect(find.byKey(const Key('search-status-filter')), findsOneWidget);
    expect(find.text('Report.pdf'), findsOneWidget);
  });

  testWidgets('rename dialog fits 200% text on a phone', (tester) async {
    _surface(tester);
    await tester.pumpWidget(_scaled(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<String>(
              context: context,
              builder: (_) => const RenameDialog(
                  initialName:
                      'Quarterly financial report for the whole year.txt',
                  isDir: false)),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Rename file'), findsOneWidget);
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets('conflict choice dialog fits 200% text on a phone',
      (tester) async {
    _surface(tester);
    await tester.pumpWidget(_scaled(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showDialog<String>(
              context: context,
              builder: (_) => const ConflictChoiceDialog(
                  original: 'Quarterly financial report for the whole year.txt',
                  copy:
                      'Quarterly financial report for the whole year (conflict dev T).txt')),
          child: const Text('open'),
        ),
      ),
    )));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Keep mine'), findsOneWidget);
    expect(find.text('Keep theirs'), findsOneWidget);
    expect(find.text('Keep both'), findsOneWidget);
  });

  testWidgets('icon-only controls on sync and search announce themselves',
      (tester) async {
    _tall(tester);
    final sync = _sync();
    addTearDown(sync.dispose);
    sync.folders.add(SyncFolderConfig(
      id: 'a',
      name: 'Documents',
      localPath: '/home/tester/Documents',
      remoteRootId: 'r1',
    )..conflictFiles = ['report (conflict dev).txt']);
    await tester.pumpWidget(_scaled(SyncPage(controller: sync)));
    await tester.pumpAndSettle();
    final syncButtons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(syncButtons, isNotEmpty);
    for (final button in syncButtons) {
      expect(button.tooltip, isNotNull,
          reason: 'an icon-only action must carry a screen-reader label');
      expect(button.tooltip, isNotEmpty);
    }

    final index = _index();
    addTearDown(index.dispose);
    await tester.runAsync(() => index.rebuild());
    await tester.pumpWidget(_scaled(AccountSearchPage(index: index)));
    await _drainRebuild(tester, index);
    final searchButtons = tester.widgetList<IconButton>(find.byType(IconButton));
    expect(searchButtons, isNotEmpty);
    for (final button in searchButtons) {
      expect(button.tooltip, isNotNull);
      expect(button.tooltip, isNotEmpty);
    }
  });
}
