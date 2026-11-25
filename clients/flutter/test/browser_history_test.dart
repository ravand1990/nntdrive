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
import 'package:nntdrive/browser_breadcrumbs.dart';

const a = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
const b = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f31';
const c = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f32';

class _Api extends ApiClient {
  _Api() : super(baseUrl: 'http://127.0.0.1:1', token: 'fixture');
  final tree = <String?, List<RemoteFile>>{};
  final parents = <String?>[];
  Completer<void>? gate;
  Object? error;
  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'test@example.invalid', 'Test', false, null, 0);
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    parents.add(parentId);
    await gate?.future;
    if (error != null) throw error!;
    return tree[parentId] ?? [];
  }
}

void main() {
  Future<({_Api api, Session session, int handle, int Function() signOuts})>
  show(WidgetTester tester, {double width = 1440, double scale = 1}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
      () => bridge.generateAccountAsync('history fixture'),
    );
    final handle =
        bridge.unlock(jsonEncode(keys!['keyfile']), 'history fixture')['handle']
            as int;
    RemoteFile folder(String id, String? parent, String name) => RemoteFile(
      id,
      parent,
      bridge.sealName(handle, id, name),
      true,
      0,
      false,
      1,
      null,
    );
    final api = _Api();
    api.tree[null] = [folder(a, null, 'Alpha')];
    api.tree[a] = [folder(b, a, 'Beta'), folder(c, a, 'Gamma')];
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
    var signOuts = 0;
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
          onSignOut: () => signOuts++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      if (api.gate != null && !api.gate!.isCompleted) api.gate!.complete();
      await tester.pumpWidget(const SizedBox());
      session.search.close();
      await operations.drain(handle);
      sync.dispose();
      bridge.lock(handle);
    });
    return (
      api: api,
      session: session,
      handle: handle,
      signOuts: () => signOuts,
    );
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  Future<void> enterBeta(WidgetTester tester) async {
    await tap(tester, find.text('Alpha'));
    await tap(tester, find.text('Beta'));
  }

  bool enabled(WidgetTester tester, String tooltip) =>
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (widget) => widget is IconButton && widget.tooltip == tooltip,
            ),
          )
          .onPressed !=
      null;
  const back = 'Back in listing history';
  const forward = 'Forward in listing history';

  testWidgets(
    'production breadcrumbs visit ancestry; history is not Up and branches truncate',
    (tester) async {
      final fixture = await show(tester);
      expect(enabled(tester, back), isFalse);
      expect(enabled(tester, forward), isFalse);
      await enterBeta(tester);
      expect(find.byKey(const ValueKey('breadcrumb-2')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('breadcrumb-1')),
          matching: find.text('Alpha'),
        ),
        findsOneWidget,
      );
      await tap(tester, find.byKey(const ValueKey('breadcrumb-0')));
      expect(fixture.api.parents.last, isNull);
      await tap(tester, find.byTooltip(back));
      expect(
        fixture.api.parents.last,
        b,
        reason: 'history returns to Beta, not its parent',
      );
      await tap(tester, find.byTooltip(forward));
      expect(fixture.api.parents.last, isNull);
      await tap(tester, find.byTooltip(back));
      await tap(tester, find.byTooltip('Refresh'));
      await tap(tester, find.byTooltip(back));
      expect(
        fixture.api.parents.last,
        a,
        reason: 'Refresh must not create duplicate visits',
      );
      await tap(tester, find.text('Gamma'));
      expect(fixture.api.parents.last, c);
      expect(enabled(tester, forward), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retained breadcrumb callbacks cannot navigate a replaced listing',
    (tester) async {
      final fixture = await show(tester);
      await enterBeta(tester);
      final visit = tester
          .widget<BrowserBreadcrumbs>(find.byType(BrowserBreadcrumbs))
          .onVisit!;
      await tap(tester, find.byTooltip('Refresh'));
      final calls = fixture.api.parents.length;
      visit(0);
      await tester.pumpAndSettle();
      expect(fixture.api.parents.length, calls);
      expect(fixture.api.parents.last, b);
    },
  );

  for (final invalid in ['missing', 'duplicate', 'file', 'ciphertext']) {
    testWidgets('history rejects $invalid ancestry without moving its cursor', (
      tester,
    ) async {
      final fixture = await show(tester);
      await enterBeta(tester);
      await tap(tester, find.byKey(const ValueKey('breadcrumb-0')));
      final root = fixture.api.tree[null]!.single;
      fixture.api.tree[null] = switch (invalid) {
        'missing' => [],
        'duplicate' => [root, root],
        'file' => [RemoteFile(a, null, root.nameEnc, false, 0, false, 1, null)],
        _ => [RemoteFile(a, null, 'invalid-envelope', true, 0, false, 1, null)],
      };
      await tap(tester, find.byTooltip(back));
      expect(find.text('My files'), findsOneWidget);
      expect(
        find.text('Location unavailable. Refresh and retry.'),
        findsOneWidget,
      );
      expect(enabled(tester, forward), isFalse);
    });
  }

  testWidgets('Alt Left Right and palette use listing history adapters', (
    tester,
  ) async {
    final fixture = await show(tester);
    await enterBeta(tester);
    Future<void> historyKey(LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
    }

    await historyKey(LogicalKeyboardKey.arrowLeft);
    expect(fixture.api.parents.last, a);
    await historyKey(LogicalKeyboardKey.arrowRight);
    expect(fixture.api.parents.last, b);
    await tap(tester, find.byTooltip('Commands (Ctrl/Cmd+K)'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Search commands'),
      'Back in listing',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(fixture.api.parents.last, a);
  });

  testWidgets(
    'history freshly authenticates renamed ancestors and rejects moved targets',
    (tester) async {
      final fixture = await show(tester);
      await enterBeta(tester);
      await tap(tester, find.byKey(const ValueKey('breadcrumb-0')));
      fixture.api.tree[null] = [
        RemoteFile(
          a,
          null,
          NativeBridge.instance.sealName(fixture.handle, a, 'Renamed Alpha'),
          true,
          0,
          false,
          1,
          null,
        ),
      ];
      await tap(tester, find.byTooltip(back));
      expect(find.text('Renamed Alpha'), findsOneWidget);
      expect(fixture.api.parents.last, b);
      await tap(tester, find.byTooltip(forward));
      fixture.api.tree[a] = [
        RemoteFile(b, c, 'invalid-envelope', true, 0, false, 1, null),
      ];
      await tap(tester, find.byTooltip(back));
      expect(find.text('My files'), findsOneWidget);
      expect(
        find.text('Location unavailable. Refresh and retry.'),
        findsOneWidget,
      );
      expect(
        enabled(tester, forward),
        isFalse,
        reason: 'failed visit must not move the cursor',
      );
      expect(find.textContaining('invalid-envelope'), findsNothing);
    },
  );

  for (final status in [401, 500]) {
    testWidgets(
      'history preliminary $status preserves sign out and redacts diagnostics',
      (tester) async {
        final fixture = await show(tester);
        await enterBeta(tester);
        await tap(tester, find.byKey(const ValueKey('breadcrumb-0')));
        fixture.api.error = ApiException(
          status,
          'private-code',
          'private diagnostic',
        );
        await tap(tester, find.byTooltip(back));
        expect(fixture.signOuts(), status == 401 ? 1 : 0);
        expect(find.textContaining('private'), findsNothing);
        expect(find.text('My files'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'suspended history cannot overwrite a newer Devices intent or decrypt after close',
    (tester) async {
      final fixture = await show(tester);
      await enterBeta(tester);
      await tap(tester, find.byKey(const ValueKey('breadcrumb-0')));
      final gate = Completer<void>();
      fixture.api.gate = gate;
      await tester.tap(find.byTooltip(back));
      await tester.pump();
      fixture.api.gate = null;
      await tap(tester, find.byKey(const ValueKey('navigation-devices')));
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('My files'), findsOneWidget);
      expect(enabled(tester, forward), isFalse);
      final closing = Completer<void>();
      fixture.api.gate = closing;
      await tester.tap(find.byTooltip(back));
      await tester.pump();
      fixture.session.search.close();
      closing.complete();
      await tester.pumpAndSettle();
      expect(find.text('Beta'), findsNothing);
      expect(enabled(tester, back), isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow enlarged breadcrumbs expose ancestors in overflow and history keys respect editing',
    (tester) async {
      final fixture = await show(tester, width: 390, scale: 2);
      await enterBeta(tester);
      await tap(tester, find.byTooltip('Ancestor folders'));
      await tap(tester, find.text('Alpha').last);
      expect(fixture.api.parents.last, a);
      await tester.enterText(find.byType(TextField), 'edit');
      final calls = fixture.api.parents.length;
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.pumpAndSettle();
      expect(fixture.api.parents.length, calls);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.tap(find.byTooltip(back));
      await tester.pumpAndSettle();
      expect(fixture.api.parents.last, b);
      expect(tester.takeException(), isNull);
    },
  );
}
