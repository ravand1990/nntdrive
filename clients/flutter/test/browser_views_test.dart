import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/browser_views.dart';
import 'package:nntdrive/browser_file_details.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';

RemoteFile file(
  String id, {
  int size = 1,
  DateTime? date,
  bool dir = false,
  bool favorite = false,
  String sealed = '',
}) =>
    RemoteFile(id, null, sealed, dir, size, favorite, 1, null, updatedAt: date);

class BrowserApi extends ApiClient {
  BrowserApi() : super(baseUrl: 'http://127.0.0.1:1', token: 'test');
  final entries = <RemoteFile>[];
  final parents = <String?>[];
  Future<void>? gate;
  bool fail = false;
  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'test@example.invalid', 'Test', false, null, 0);
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    parents.add(parentId);
    if (gate != null) await gate;
    if (fail) throw StateError('Synthetic listing failure');
    return parentId == null ? List.of(entries) : [];
  }
}

class BrowserSync extends SyncController {
  BrowserSync({required super.server, required super.token,
      required super.handle, required super.api});
  void evidenceChanged() => notifyListeners();
}

void main() {
  test(
    'sort/filter uses decrypted names, deterministic ties and cached results',
    () {
      final names = {'c': 'beta', 'b': 'Alpha', 'a': 'Alpha', 'd': 'alpha'};
      var reads = 0;
      final listing = BrowserListing(
        [file('c'), file('b'), file('d'), file('a')],
        (f) {
          reads++;
          return names[f.id]!;
        },
      );
      final result = listing.visible(BrowserSort.name, false, '');
      expect(result.map((f) => f.id), ['a', 'b', 'd', 'c']);
      expect(
        identical(result, listing.visible(BrowserSort.name, false, '')),
        isTrue,
      );
      expect(listing.visible(BrowserSort.name, false, 'ALP').map((f) => f.id), [
        'a',
        'b',
        'd',
      ]);
      expect(listing.visible(BrowserSort.name, true, '').map((f) => f.id), [
        'c',
        'a',
        'b',
        'd',
      ]);
      expect(reads, 4);
      expect(() => result.clear(), throwsUnsupportedError);
    },
  );

  test(
    'size and modification compare values, instants, ties and unknown dates',
    () {
      final listing = BrowserListing([
        file('z', size: 1000, dir: true),
        file('b', size: 2, date: DateTime.parse('2026-01-01T01:00:00+01:00')),
        file('a', size: 2, date: DateTime.parse('2026-01-01T00:00:00Z')),
        file('c', size: 3, date: DateTime.utc(2025)),
      ], (f) => f.id);
      expect(listing.visible(BrowserSort.size, false, '').map((f) => f.id), [
        'z',
        'a',
        'b',
        'c',
      ]);
      expect(listing.visible(BrowserSort.size, true, '').map((f) => f.id), [
        'c',
        'a',
        'b',
        'z',
      ]);
      expect(listing.visible(BrowserSort.size, true, 'b').single.id, 'b');
      expect(
        listing.visible(BrowserSort.modified, false, '').map((f) => f.id),
        ['c', 'a', 'b', 'z'],
      );
      expect(listing.visible(BrowserSort.modified, true, '').map((f) => f.id), [
        'a',
        'b',
        'c',
        'z',
      ]);
    },
  );

  for (final mode in BrowserView.values) {
    testWidgets(
      '10k ${mode.name} fixture is lazy and scrolls with opaque callbacks',
      (tester) async {
        final files = List.generate(10000, (i) => file('opaque-$i'));
        var built = 0;
        String? opened;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: BrowserFilesView(
                files: files,
                view: mode,
                nameFor: (f) {
                  built++;
                  return f.id;
                },
                availabilityFor: (_) => LocalAvailability.unknown,
                pinned: (_) => false,
                onOpen: (f) => opened = f.id,
                onActions: (_) {},
                onReveal: (_) {},
                onDetails: (_) {},
              ),
            ),
          ),
        );
        expect(built, lessThan(100));
        expect(find.byKey(const ValueKey('opaque-9999')), findsNothing);
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, -1200),
        );
        await tester.pumpAndSettle();
        final visible = find.byType(BrowserFileTile).hitTestable().first;
        final target = tester.widget<BrowserFileTile>(visible).file.id;
        await tester.tap(
          find.descendant(of: visible, matching: find.text(target)),
        );
        expect(opened, target);
        expect(built, lessThan(100));
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final width in [320.0, 600.0, 1024.0, 1440.0]) {
    for (final mode in BrowserView.values) {
      testWidgets('${mode.name} $width at 200% preserves badges/status/actions', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final calls = <String>[];
        final entry = file('opaque', favorite: true);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: Scaffold(
              body: Column(
                children: [
                  BrowserViewControls(
                    view: mode,
                    sort: BrowserSort.name,
                    descending: false,
                    onView: (_) {},
                    onSort: (_) {},
                    onDirection: () {},
                  ),
                  Expanded(
                    child: BrowserFilesView(
                      files: [entry],
                      view: mode,
                      nameFor: (_) =>
                          'A very long filename with multiple words and suffix.txt',
                      availabilityFor: (_) => LocalAvailability.unknown,
                      pinned: (_) => true,
                      onOpen: (f) => calls.add('open:${f.id}'),
                      onActions: (f) => calls.add('actions:${f.id}'),
                      onReveal: (f) => calls.add('reveal:${f.id}'),
                      onDetails: (f) => calls.add('details:${f.id}'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        expect(find.textContaining('Unknown'), findsOneWidget);
        expect(find.byIcon(Icons.star), findsOneWidget);
        expect(find.byIcon(Icons.offline_pin), findsOneWidget);
        final more = find.byTooltip(
          'More actions for A very long filename with multiple words and suffix.txt',
        );
        expect(tester.getSize(more).shortestSide, greaterThanOrEqualTo(48));
        final details = find.byTooltip(
          'Details for A very long filename with multiple words and suffix.txt',
        );
        expect(tester.getSize(details).shortestSide, greaterThanOrEqualTo(48));
        await tester.tap(details);
        await tester.tap(more);
        await tester.tap(find.textContaining('A very long filename'));
        expect(calls, ['details:opaque', 'actions:opaque', 'open:opaque']);
        final reveal = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.folder_open_outlined),
        );
        expect(reveal.onPressed, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'grid uses live conflict evidence and enabled confined reveal callback',
    (tester) async {
      final folder = SyncFolderConfig(
        id: 'sync',
        name: 'Sync',
        localPath: '/local',
        remoteRootId: 'root',
      );
      final state = LocalAvailability(
        'Conflict',
        'Review both preserved versions.',
        path: '/local/copy',
        folder: folder,
        relativePath: 'copy',
      );
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BrowserFilesView(
              files: [file('opaque')],
              view: BrowserView.grid,
              nameFor: (_) => 'copy',
              availabilityFor: (_) => state,
              pinned: (_) => false,
              onOpen: (_) {},
              onActions: (_) {},
              onReveal: (f) => calls.add(f.id),
              onDetails: (_) {},
            ),
          ),
        ),
      );
      expect(find.textContaining('Conflict'), findsOneWidget);
      expect(find.byTooltip('Review both preserved versions.'), findsOneWidget);
      await tester.tap(find.byTooltip('Show in folder'));
      expect(calls, ['opaque']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real FilesPage switches grid, sort/filter and opens original opaque folder/menu',
    (tester) async {
      final bridge = NativeBridge.instance;
      final keys = await tester.runAsync(
        () => bridge.generateAccountAsync('browser views password'),
      );
      final handle =
          bridge.unlock(
                jsonEncode(keys!['keyfile']),
                'browser views password',
              )['handle']
              as int;
      final api = BrowserApi();
      const ids = [
        '00000000-0000-4000-8000-000000000001',
        '00000000-0000-4000-8000-000000000002',
      ];
      api.entries.addAll([
        file(
          ids[0],
          dir: true,
          date: DateTime.utc(2026),
          sealed: bridge.sealName(handle, ids[0], 'Zebra'),
        ),
        file(
          ids[1],
          size: 99,
          favorite: true,
          sealed: bridge.sealName(handle, ids[1], 'Alpha'),
        ),
      ]);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final operations = SessionOperations();
      final session = Session(
        server: api.baseUrl,
        token: 'test',
        handle: handle,
        accountId: 'account',
        email: 'test@example.invalid',
        operations: operations,
      );
      final sync = BrowserSync(
        server: api.baseUrl,
        token: 'test',
        handle: handle,
        api: api,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: FilesPage(
            session: session,
            sync: sync,
            operations: operations,
            updates: UpdateChecks(
              check: () async => null,
              prompt: (_) async => true,
            ),
            themeMode: ThemeMode.light,
            onTheme: (_) {},
            onSignOut: () {},
            api: api,
          ),
        ),
      );
      await tester.pumpAndSettle();
      var before = api.parents.length;
      Future<void> checkDetails() async {
        for (final name in ['Alpha', 'Zebra']) {
          await tester.tap(find.byTooltip('Details for $name'));
          await tester.pumpAndSettle();
          expect(find.byType(BrowserFileDetails), findsOneWidget);
          expect(find.text('File details'), findsOneWidget);
          expect(find.text(name), findsWidgets);
          expect(find.text(name == 'Alpha' ? '99 bytes'
              : 'Not calculated for folders (not an aggregate).'), findsOneWidget);
          expect(api.parents.length, before,
              reason: 'Opening details must not list or download');
          await tester.tap(find.text('Close details'));
          await tester.pumpAndSettle();
          expect(find.byType(BrowserFileDetails), findsNothing);
        }
      }
      await checkDetails();
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      for (final mode in BrowserView.values) {
        await tester.tap(find.text(mode == BrowserView.list ? 'List ✓' : 'Grid'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Details for Alpha'));
        await tester.pumpAndSettle();
        final pane = find.byKey(const ValueKey('browser-details-pane'));
        expect(pane, findsOneWidget);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.getSize(pane).width, 320);
        expect(tester.getSize(find.byType(BrowserFilesView)).width,
            greaterThanOrEqualTo(480));
        expect(find.text('99 bytes'), findsOneWidget);
        final oldClose = tester.widget<BrowserFileDetails>(find.byType(BrowserFileDetails)).onClose!;
        // Browser controls remain usable while the nonmodal pane is open.
        await tester.tap(find.byTooltip('Details for Zebra'));
        await tester.pumpAndSettle();
        expect(find.text('Not calculated for folders (not an aggregate).'), findsOneWidget);
        expect(find.text('99 bytes'), findsNothing);
        oldClose();
        await tester.pumpAndSettle();
        expect(pane, findsOneWidget, reason: 'Old Close must not dismiss a replacement');
        expect(api.parents.length, before);
        final close = find.widgetWithText(TextButton, 'Close details');
        expect(tester.getSize(close).shortestSide, greaterThanOrEqualTo(48));
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(pane, findsNothing);
      }
      for (final dismiss in ['escape', 'back', 'controller']) {
        await tester.tap(find.byTooltip('Details for Alpha'));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('browser-details-pane')), findsOneWidget);
        if (dismiss == 'escape') {
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        } else if (dismiss == 'back') {
          await tester.binding.handlePopRoute();
        } else {
          sync.evidenceChanged();
        }
        await tester.pumpAndSettle();
        expect(find.byType(BrowserFileDetails), findsNothing);
      }
      // Refresh invalidates both a frozen pane and retained row callbacks while
      // loading and on failure, even if transport returns the same model object.
      final previous = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      await tester.tap(find.byTooltip('Details for Alpha'));
      await tester.pumpAndSettle();
      final suspended = Completer<void>();
      api.gate = suspended.future;
      final refreshing = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
      await tester.pump();
      expect(find.byType(BrowserFileDetails), findsNothing);
      previous.onDetails(previous.files.first);
      await tester.pump();
      expect(find.byType(BrowserFileDetails), findsNothing);
      api.fail = true;
      suspended.complete();
      await refreshing;
      await tester.pumpAndSettle();
      previous.onDetails(previous.files.first);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      api.gate = null;
      api.fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      before = api.parents.length;
      previous.onDetails(previous.files.first);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing,
          reason: 'A retained callback cannot reopen even reused transport models');
      // Crossing the docking boundary dismisses, rather than migrating a stale
      // observation into a modal route or retaining an invisible pane.
      await tester.tap(find.byTooltip('Details for Alpha'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1024, 900);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      await tester.tap(find.byTooltip('Details for Alpha'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      tester.view.physicalSize = const Size(1440, 900);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      await tester.tap(find.text('List'));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('Alpha')).dy,
        lessThan(tester.getTopLeft(find.text('Zebra')).dy),
      );
      await tester.tap(find.text('Grid'));
      await tester.pumpAndSettle();
      expect(find.byType(GridView), findsOneWidget);
      await checkDetails();
      await tester.tap(find.byTooltip('Sort files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Size').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserFilesView>(find.byType(BrowserFilesView))
            .files
            .first
            .id,
        ids[0],
      );
      await tester.tap(find.text('Ascending'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserFilesView>(find.byType(BrowserFilesView))
            .files
            .first
            .id,
        ids[1],
      );
      await tester.tap(find.byTooltip('Sort files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Modified').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<BrowserFilesView>(find.byType(BrowserFilesView))
            .files
            .first
            .id,
        ids[0],
      );
      await tester.enterText(find.byType(TextField), 'ALP');
      await tester.pumpAndSettle();
      expect(find.text('Zebra'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(
        api.parents.length,
        before,
        reason: 'view/sort/filter must not list HTTP',
      );
      await tester.tap(find.byTooltip('More actions for Alpha'));
      await tester.pumpAndSettle();
      expect(find.text('Remove favorite'), findsOneWidget);
      expect(find.text('Keep offline'), findsOneWidget);
      expect(find.text('Copy file'), findsOneWidget);
      Navigator.of(tester.element(find.text('Copy file'))).pop();
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      final oldView = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      final oldFile = oldView.files.firstWhere((f) => f.id == ids[1]);
      await tester.tap(find.byTooltip('Details for Alpha'));
      await tester.pumpAndSettle();
      api.entries[1] = file(ids[1], size: 777,
          sealed: bridge.sealName(handle, ids[1], 'Changed'));
      final refresh = tester.widget<RefreshIndicator>(
          find.byType(RefreshIndicator, skipOffstage: false));
      await refresh.onRefresh();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      oldView.onDetails(oldFile);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing,
          reason: 'Stale callbacks must not resurrect replaced listing entries');
      await tester.tap(find.byTooltip('Details for Changed'));
      await tester.pumpAndSettle();
      expect(find.text('777 bytes'), findsOneWidget);
      // The production controller notification must invalidate frozen evidence.
      sync.evidenceChanged();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      final currentView = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      await tester.tap(find.byTooltip('Details for Changed'));
      await tester.pumpAndSettle();
      currentView.onOpen(currentView.files.firstWhere((f) => f.id == ids[0]));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      expect(api.parents, contains(ids[0]));
      expect(find.byTooltip('Up one folder'), findsOneWidget);
      await tester.tap(find.byTooltip('Up one folder'));
      await tester.pumpAndSettle();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      for (final width in [320.0, 600.0, 1024.0, 1440.0]) {
        tester.view.physicalSize = Size(width, 800);
        tester.view.devicePixelRatio = 1;
        await tester.pump();
        for (final mode in BrowserView.values) {
          await tester.tap(
            find.text(mode == BrowserView.list ? 'List' : 'Grid'),
          );
          await tester.pumpAndSettle();
          expect(
            tester.widget<BrowserFilesView>(find.byType(BrowserFilesView)).view,
            mode,
          );
          final enlargedView = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
          enlargedView.onDetails(enlargedView.files.firstWhere((f) => f.id == ids[1]));
          await tester.pumpAndSettle();
          expect(find.byKey(const ValueKey('browser-details-pane')),
              width >= 1200 ? findsOneWidget : findsNothing);
          expect(find.byType(AlertDialog), width >= 1200 ? findsNothing : findsOneWidget);
          final detailsScroll = tester.state<ScrollableState>(find.descendant(
            of: find.byType(BrowserFileDetails), matching: find.byType(Scrollable)).first);
          detailsScroll.position.jumpTo(detailsScroll.position.maxScrollExtent);
          await tester.pumpAndSettle();
          final enlargedClose = find.widgetWithText(TextButton, 'Close details');
          expect(tester.getBottomLeft(find.textContaining('may be stale')).dy,
              lessThanOrEqualTo(tester.getTopLeft(enlargedClose).dy));
          expect(tester.getSize(enlargedClose).height, greaterThanOrEqualTo(48));
          await tester.tap(enlargedClose);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
      }
      tester.view.physicalSize = const Size(1440, 800);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      final page = tester.widget<FilesPage>(find.byType(FilesPage));
      final disposedView = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      disposedView.onDetails(disposedView.files.first);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsOneWidget);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      disposedView.onDetails(disposedView.files.first);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      await tester.pumpWidget(MaterialApp(home: page));
      await tester.pumpAndSettle();
      final closingView = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      closingView.onDetails(closingView.files.first);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('browser-details-pane')), findsOneWidget);
      session.search.close();
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      closingView.onDetails(closingView.files.first);
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsNothing);
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      bridge.lock(handle);
    },
  );
}
