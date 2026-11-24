import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';
import 'package:nntdrive/search_page.dart';
import 'package:nntdrive/activity_page.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:nntdrive/trash_page.dart';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'http://127.0.0.1:1', token: 'fixture');
  late RemoteFile folder;
  int calls = 0;
  Completer<void>? gate;
  bool fail = false;
  final parents = <String?>[];
  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'test@example.invalid', 'Tester', false, null, 0);
  @override
  Future<List<AccountRoot>> listRoots() async => [
    AccountRoot(
      rootId: 'root',
      kind: 'global',
      nodeId: folder.id,
      nameEnc: folder.nameEnc,
    ),
  ];
  @override
  Future<TrashListing> trash() async => TrashListing(30, []);
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    calls++;
    parents.add(parentId);
    await gate?.future;
    if (fail) throw ApiException(500, 'fixture', 'unavailable');
    return parentId == null ? [folder] : [];
  }
}

Future<void> chord(
  WidgetTester tester,
  LogicalKeyboardKey key, {
  bool meta = false,
  bool shift = false,
  bool alt = false,
}) async {
  final modifier = alt
      ? LogicalKeyboardKey.altLeft
      : meta
      ? LogicalKeyboardKey.metaLeft
      : LogicalKeyboardKey.controlLeft;
  await tester.sendKeyDownEvent(modifier);
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

Future<void> turns(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void main() {
  Future<({_Api api, Session session, SyncController sync})> showBrowser(
    WidgetTester tester, {
    double width = 1440,
    double scale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
      () => bridge.generateAccountAsync('commands fixture'),
    );
    final handle =
        bridge.unlock(
              jsonEncode(keys!['keyfile']),
              'commands fixture',
            )['handle']
            as int;
    const id = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final api = _Api()
      ..folder = RemoteFile(
        id,
        null,
        bridge.sealName(handle, id, 'Authenticated Global'),
        true,
        0,
        false,
        1,
        null,
      );
    final operations = SessionOperations();
    final session = Session(
      server: api.baseUrl,
      token: 'fixture',
      handle: handle,
      accountId: 'account',
      email: 'test@example.invalid',
      operations: operations,
    );
    final sync = SyncController(
      server: api.baseUrl,
      token: 'fixture',
      handle: handle,
      api: api,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: FilesPage(
          session: session,
          sync: sync,
          operations: operations,
          api: api,
          updates: UpdateChecks(
            check: () async => null,
            prompt: (_) async => true,
          ),
          themeMode: ThemeMode.light,
          onTheme: (_) {},
          onSignOut: () {},
        ),
      ),
    );
    await turns(tester);
    addTearDown(() async {
      api.gate?.complete();
      api.gate = null;
      await tester.pumpWidget(const SizedBox());
      session.search.close();
      await operations.drain(handle);
      sync.dispose();
      bridge.lock(handle);
    });
    return (api: api, session: session, sync: sync);
  }

  testWidgets(
    'production palette keyboard search invokes Refresh and focus filter',
    (tester) async {
      final fixture = await showBrowser(tester);
      await chord(tester, LogicalKeyboardKey.keyK);
      expect(find.text('Browser commands'), findsOneWidget);
      final search = find.widgetWithText(TextField, 'Search commands');
      await tester.enterText(search, 'refresh');
      final before = fixture.api.calls;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await turns(tester);
      expect(fixture.api.calls, greaterThan(before));
      expect(find.text('Browser commands'), findsNothing);
      await chord(tester, LogicalKeyboardKey.keyK, meta: true);
      await tester.enterText(search, 'folder');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
    },
  );

  testWidgets('palette uses authenticated locations and real page adapters', (
    tester,
  ) async {
    final fixture = await showBrowser(tester);
    Future<void> command(String query) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.byTooltip('Commands (Ctrl/Cmd+K)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search commands'),
        query,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await turns(tester);
    }

    await command('global');
    expect(fixture.api.parents.last, fixture.api.folder.id);
    expect(find.text('Authenticated Global'), findsWidgets);
    await chord(tester, LogicalKeyboardKey.arrowUp, alt: true);
    await turns(tester);
    expect(fixture.api.parents.last, isNull);
    await command('activity');
    expect(find.byType(ActivityPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(ActivityPage))).pop();
    await turns(tester);
    await chord(tester, LogicalKeyboardKey.keyF);
    await turns(tester);
    expect(find.byType(AccountSearchPage), findsOneWidget);
  });

  testWidgets('pointer palette rows use current page and location adapters', (
    tester,
  ) async {
    final fixture = await showBrowser(tester);
    Future<void> choose(String id, String query) async {
      await tester.tap(find.byTooltip('Commands (Ctrl/Cmd+K)'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Search commands'),
        query,
      );
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('command-$id')));
      await turns(tester);
    }

    await choose('global', 'global');
    expect(fixture.api.parents.last, fixture.api.folder.id);
    await choose('devices', 'devices');
    expect(fixture.api.parents.last, isNull);
    await choose('sync', 'sync');
    expect(find.byType(SyncPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(SyncPage))).pop();
    await turns(tester);
    await choose('trash', 'trash');
    expect(find.byType(TrashPage), findsOneWidget);
    Navigator.of(tester.element(find.byType(TrashPage))).pop();
    await turns(tester);
    await choose('settings', 'settings');
    expect(find.text('test@example.invalid'), findsOneWidget);
    expect(find.byType(BottomSheet), findsOneWidget);
  });

  testWidgets('shortcuts respect editing, modal and covered routes', (
    tester,
  ) async {
    final fixture = await showBrowser(tester);
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'editing');
    final before = fixture.api.calls;
    for (final key in [
      LogicalKeyboardKey.keyK,
      LogicalKeyboardKey.keyF,
      LogicalKeyboardKey.slash,
    ]) {
      await chord(tester, key);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(find.text('Browser commands'), findsNothing);
    expect(find.byType(AccountSearchPage), findsNothing);
    expect(fixture.api.calls, before);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'editing',
    );
    // Escape restores a known browser focus before checking route coverage.
    await tester.tap(find.byTooltip('Commands (Ctrl/Cmd+K)'));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(FilesPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(title: Text('Other modal')),
      ),
    );
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    expect(find.text('Browser commands'), findsNothing);
    expect(fixture.api.calls, before);
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigation-activity')));
    await tester.pumpAndSettle();
    await chord(tester, LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    expect(find.text('Browser commands'), findsNothing);
    expect(fixture.api.calls, before);
  });

  testWidgets('loading, changed and closed sessions reject commands', (
    tester,
  ) async {
    final fixture = await showBrowser(tester);
    await chord(tester, LogicalKeyboardKey.keyK);
    expect(find.text('Browser commands'), findsOneWidget);
    // A real controller notification invalidates the frozen palette.
    fixture.sync.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('Browser commands'), findsNothing);
    fixture.api.gate = Completer<void>();
    final beforeLoading = fixture.api.calls;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    expect(fixture.api.calls, greaterThan(beforeLoading));
    await chord(tester, LogicalKeyboardKey.keyK);
    expect(find.text('Browser commands'), findsNothing);
    final gate = fixture.api.gate!;
    fixture.api.gate = null;
    gate.complete();
    await turns(tester);
    await chord(tester, LogicalKeyboardKey.keyK);
    expect(find.text('Browser commands'), findsOneWidget);
    fixture.session.search.close();
    await tester.pumpAndSettle();
    expect(find.text('Browser commands'), findsNothing);
    final before = fixture.api.calls;
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await chord(tester, LogicalKeyboardKey.keyK);
    expect(fixture.api.calls, before);
    expect(find.text('Browser commands'), findsNothing);
  });

  testWidgets(
    'narrow 200 percent palette and shortcut help scroll with 48dp rows',
    (tester) async {
      await showBrowser(tester, width: 320, scale: 2);
      await tester.tap(find.byTooltip('Commands (Ctrl/Cmd+K)'));
      await tester.pumpAndSettle();
      expect(find.text('Browser commands'), findsOneWidget);
      expect(find.byKey(const ValueKey('command-refresh')), findsOneWidget);
      for (final element in find.byType(ListTile).evaluate()) {
        expect(
          tester.getSize(find.byWidget(element.widget)).height,
          greaterThanOrEqualTo(48),
        );
      }
      await tester.enterText(
        find.widgetWithText(TextField, 'Search commands'),
        'help',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('Browser shortcuts'), findsOneWidget);
      await tester.ensureVisible(
        find.textContaining('Selection commands are unfinished'),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Browser shortcuts'), findsNothing);
    },
  );

  testWidgets(
    'shortcut inventory, disabled parent and keyboard focus adapters',
    (tester) async {
      final fixture = await showBrowser(tester);
      final initial = fixture.api.calls;
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await turns(tester);
      expect(fixture.api.calls, greaterThan(initial));
      final before = fixture.api.calls;
      await chord(tester, LogicalKeyboardKey.arrowUp, alt: true);
      await turns(tester);
      expect(fixture.api.calls, before);
      await chord(tester, LogicalKeyboardKey.slash, meta: true);
      await tester.pumpAndSettle();
      expect(find.text('Browser shortcuts'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.keyK);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Already at the browser root'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Search commands'),
        'up one',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Browser commands'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Search commands'),
        'no-such-command',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('No matching commands'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await chord(tester, LogicalKeyboardKey.keyF, shift: true);
      await tester.pump();
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.focusNode!.hasFocus, isTrue);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'composing',
          selection: TextSelection.collapsed(offset: 9),
          composing: TextRange(start: 0, end: 9),
        ),
      );
      await tester.pump();
      await chord(tester, LogicalKeyboardKey.keyK, meta: true);
      expect(field.controller!.text, 'composing');
      await chord(tester, LogicalKeyboardKey.keyA);
      for (final key in [
        LogicalKeyboardKey.f2,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.f5,
      ]) {
        await tester.sendKeyEvent(key);
      }
      expect(find.text('Browser commands'), findsNothing);
      expect(fixture.api.calls, before);
      expect(
        field.controller!.text,
        '',
        reason: 'native text select-all/delete remain editable',
      );
    },
  );

  testWidgets('refresh error and disposed page cannot retain a palette', (
    tester,
  ) async {
    final fixture = await showBrowser(tester);
    await chord(tester, LogicalKeyboardKey.keyK);
    await tester.pumpAndSettle();
    // Drive the production Refresh adapter while the palette is present.
    fixture.api.fail = true;
    final refresh = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == 'Refresh',
        skipOffstage: false,
      ),
    );
    refresh.onPressed!();
    await turns(tester);
    expect(find.text('Browser commands'), findsNothing);
    final before = fixture.api.calls;
    await chord(tester, LogicalKeyboardKey.keyK);
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    expect(fixture.api.calls, before);
    fixture.api.fail = false;
    refresh.onPressed!();
    await turns(tester);
    await tester.tap(find.byTooltip('Commands (Ctrl/Cmd+K)'));
    await tester.pumpAndSettle();
    expect(find.text('Browser commands'), findsOneWidget);
    final context = tester.element(find.byType(FilesPage, skipOffstage: false));
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Replacement')),
      ),
    );
    await turns(tester);
    await tester.pumpAndSettle();
    expect(find.text('Browser commands'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
