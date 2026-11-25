import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/browser_file_details.dart';
import 'package:nntdrive/browser_views.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/update_checks.dart';

import 'browser_views_test.dart' show BrowserApi, BrowserSync, file;

void main() {
  Future<void> tapLabel(WidgetTester tester, String label) async {
    final target = find.text(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target);
    await tester.pumpAndSettle();
  }
  Future<(Session, BrowserApi, FilesPage)> mount(WidgetTester tester,
      {int count = 3}) async {
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
        () => bridge.generateAccountAsync('selection fixture password'));
    final handle = bridge.unlock(jsonEncode(keys!['keyfile']),
        'selection fixture password')['handle'] as int;
    final api = BrowserApi();
    for (var i = 0; i < count; i++) {
      final id = '00000000-0000-4000-8000-${i.toString().padLeft(12, '0')}';
      api.entries.add(file(id, dir: i == 0, size: i + 10,
          sealed: bridge.sealName(handle, id, 'Entry ${i.toString().padLeft(5, '0')}')));
    }
    final operations = SessionOperations();
    final session = Session(server: api.baseUrl, token: 'test', handle: handle,
        accountId: 'account', email: 'test@example.invalid', operations: operations);
    final sync = BrowserSync(server: api.baseUrl, token: 'test', handle: handle, api: api);
    final page = FilesPage(session: session, sync: sync, operations: operations,
        updates: UpdateChecks(check: () async => null, prompt: (_) async => true),
        themeMode: ThemeMode.light, onTheme: (_) {}, onSignOut: () {}, api: api);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      sync.dispose();
      session.search.close();
      bridge.lock(handle);
    });
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
    return (session, api, page);
  }

  Future<void> select(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Select items'));
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
  }

  for (final mode in BrowserView.values) {
    testWidgets('production ${mode.name} selection is read-only, exact and filtered', (tester) async {
      final (_, api, _) = await mount(tester);
      if (mode == BrowserView.grid) {
        await tester.tap(find.text('Grid'));
        await tester.pumpAndSettle();
      }
      final calls = api.parents.length;
      await select(tester);
      expect(find.byTooltip('More actions for Entry 00000'), findsNothing);
      await tester.tap(find.text('Entry 00000'));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      expect(api.parents.length, calls, reason: 'Selection must not navigate');
      final view = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      expect(identical(view.files.first, api.entries.first), isTrue);
      await tapLabel(tester, 'Selection details');
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileDetails), findsOneWidget);
      expect(tester.widget<BrowserFileDetails>(find.byType(BrowserFileDetails)).file,
          same(api.entries.first));
      await tester.tap(find.text('Close details'));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Select all visible');
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      expect(find.text('Selection details'), findsNothing);
      await tester.tap(find.text(mode == BrowserView.list ? 'Grid' : 'List'));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      await tester.tap(find.text('Ascending'));
      await tester.pumpAndSettle();
      expect(find.text('3 selected'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '00001');
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget,
          reason: 'Filter changes cannot retain hidden selections');
      await tapLabel(tester, 'Select all visible');
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);
      await tapLabel(tester, 'Selection details');
      await tester.pumpAndSettle();
      expect(tester.widget<BrowserFileDetails>(find.byType(BrowserFileDetails)).file,
          same(api.entries[1]));
      await tester.tap(find.text('Close details'));
      await tester.pumpAndSettle();
      await tapLabel(tester, 'Clear selection');
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
      await tapLabel(tester, 'Exit selection');
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      expect(api.parents.length, calls);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entry 00000'));
      await tester.pumpAndSettle();
      expect(api.parents, contains(api.entries.first.id),
          reason: 'Ordinary open survives exit');
    });
  }

  testWidgets('refresh/error/navigation/close/dispose reject retained selection callbacks', (tester) async {
    final (session, api, page) = await mount(tester);
    await select(tester);
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.textContaining(' selected'), findsNothing);
    await select(tester);
    final oldTile = tester.widget<ListTile>(find.ancestor(
        of: find.text('Entry 00000'), matching: find.byType(ListTile)));
    await tester.tap(find.text('Entry 00000'));
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    api.gate = gate.future;
    final refreshing = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh();
    await tester.pump();
    oldTile.onTap!();
    api.fail = true;
    gate.complete();
    await refreshing;
    await tester.pumpAndSettle();
    expect(find.textContaining(' selected'), findsNothing);
    api.fail = false;
    api.gate = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await select(tester);
    oldTile.onTap!();
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tester.tap(find.text('Entry 00001'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Exit selection');
    await tester.pumpAndSettle();
    await select(tester);
    oldTile.onTap!();
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    await tapLabel(tester, 'Exit selection');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entry 00000'));
    await tester.pumpAndSettle();
    expect(find.textContaining(' selected'), findsNothing);
    await tester.tap(find.byTooltip('Up one folder'));
    await tester.pumpAndSettle();
    await select(tester);
    await tester.tap(find.text('Entry 00001'));
    await tester.pumpAndSettle();
    final disposedTile = tester.widget<ListTile>(find.ancestor(
        of: find.text('Entry 00001'), matching: find.byType(ListTile)));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    disposedTile.onTap!();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(MaterialApp(home: page));
    await tester.pumpAndSettle();
    await select(tester);
    await tester.tap(find.text('Entry 00001'));
    await tester.pumpAndSettle();
    session.search.close();
    await tester.pumpAndSettle();
    oldTile.onTap!();
    await tester.pumpAndSettle();
    expect(find.textContaining(' selected'), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
  });

  testWidgets('system Back dismisses docked details before selection', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    await select(tester);
    await tester.tap(find.text('Entry 00001'));
    await tester.pumpAndSettle();
    await tapLabel(tester, 'Selection details');
    expect(find.byKey(const ValueKey('browser-details-pane')), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BrowserFileDetails), findsNothing);
    expect(find.text('1 selected'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byTooltip('Select items'), findsOneWidget);
  });

  testWidgets('10k production selection keeps list/grid construction bounded', (tester) async {
    final (_, api, _) = await mount(tester, count: 10000);
    final calls = api.parents.length;
    await select(tester);
    for (final mode in BrowserView.values) {
      if (mode == BrowserView.grid) {
        await tester.tap(find.text('Grid'));
        await tester.pumpAndSettle();
      }
      await tapLabel(tester, 'Select all visible');
      await tester.pumpAndSettle();
      expect(find.text('10000 selected'), findsOneWidget);
      expect(find.byType(BrowserFileTile).evaluate().length, lessThan(80));
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).every((c) => c.value!), isTrue);
      await tester.drag(find.byType(BrowserFilesView), const Offset(0, -700));
      await tester.pumpAndSettle();
      expect(find.byType(BrowserFileTile).evaluate().length, lessThan(80));
      expect(tester.widgetList<Checkbox>(find.byType(Checkbox)).every((c) => c.value!), isTrue);
      await tester.tap(find.byType(Checkbox).hitTestable().first);
      await tester.pumpAndSettle();
      expect(find.text('9999 selected'), findsOneWidget);
      await tapLabel(tester, 'Clear selection');
      await tester.pumpAndSettle();
      expect(find.text('0 selected'), findsOneWidget);
    }
    expect(api.parents.length, calls);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection controls support narrow 200% text and preserve editing select-all', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(tester);
    await select(tester);
    for (final label in ['Select all visible', 'Clear selection', 'Exit selection']) {
      final button = find.widgetWithText(TextButton, label);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      expect(tester.getSize(button).shortestSide, greaterThanOrEqualTo(48));
    }
    await tester.enterText(find.byType(TextField), 'Entry');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(find.text('0 selected'), findsOneWidget);
    expect(tester.widget<EditableText>(find.byType(EditableText)).controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5));
    await tester.tap(find.text('Grid'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Checkbox).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox).hitTestable().first);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    expect(tester.getSize(find.byType(Checkbox).first).shortestSide,
        greaterThanOrEqualTo(48));
    expect(tester.takeException(), isNull);
  });
}
