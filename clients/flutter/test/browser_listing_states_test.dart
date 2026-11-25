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

// Same real native sealed-name / authenticated Session fixture boundary as
// browser_commands_test. Transport alone is injected (widget HTTP overrides).
class _Api extends ApiClient {
  _Api() : super(baseUrl: 'http://127.0.0.1:1', token: 'fixture');
  List<RemoteFile> files = [];
  Completer<void>? gate = Completer<void>();
  Object? failure;
  int calls = 0;
  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'test@example.invalid', 'Tester', false, null, 0);
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    calls++;
    await gate?.future;
    if (failure case final Object error) throw error;
    return files;
  }
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
  Future<
    ({
      _Api api,
      Session session,
      SessionOperations operations,
      int Function() signouts,
    })
  >
  showBrowser(
    WidgetTester tester, {
    double width = 1440,
    double scale = 1,
    Brightness brightness = Brightness.light,
    bool reducedMotion = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
      () => bridge.generateAccountAsync('listing fixture'),
    );
    final handle =
        bridge.unlock(jsonEncode(keys!['keyfile']), 'listing fixture')['handle']
            as int;
    const id = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final api = _Api()
      ..files = [
        RemoteFile(
          id,
          null,
          bridge.sealName(handle, id, 'Authenticated document.txt'),
          false,
          12,
          false,
          1,
          null,
        ),
      ];
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
    var signouts = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.teal,
            brightness: brightness,
          ),
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reducedMotion,
          ),
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
          themeMode: ThemeMode.system,
          onTheme: (_) {},
          onSignOut: () => signouts++,
        ),
      ),
    );
    await turns(tester);
    addTearDown(() async {
      if (api.gate case final gate? when !gate.isCompleted) gate.complete();
      api.gate = null;
      await tester.pumpWidget(const SizedBox());
      session.search.close();
      await operations.drain(handle);
      sync.dispose();
      bridge.lock(handle);
    });
    return (
      api: api,
      session: session,
      operations: operations,
      signouts: () => signouts,
    );
  }

  testWidgets(
    'suspended authenticated listing is static, announced once, then List/Grid',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final f = await showBrowser(tester);
      expect(f.api.calls, 1);
      expect(find.byKey(const ValueKey('browser-loading')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.bySemanticsLabel('Loading folder'), findsOneWidget);
      expect(find.text('This folder is empty'), findsNothing);
      expect(find.text('Authenticated document.txt'), findsNothing);
      // The skeleton schedules neither frames nor timers (normal and reduced motion).
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      final before = f.api.calls;
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();
      expect(f.api.calls, before); // existing keyboard admission stays closed
      f.api.gate!.complete();
      f.api.gate = null;
      await turns(tester);
      expect(find.byKey(const ValueKey('browser-loading')), findsNothing);
      expect(find.text('Authenticated document.txt'), findsOneWidget);
      await tester.tap(find.text('Grid'));
      await tester.pumpAndSettle();
      expect(find.text('Authenticated document.txt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('loading becomes actionable empty; create uses existing dialog', (
    tester,
  ) async {
    final f = await showBrowser(tester);
    f.api.files = [];
    f.api.gate!.complete();
    f.api.gate = null;
    await turns(tester);
    expect(find.text('This folder is empty'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Upload a file'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Create folder'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('New folder'), findsOneWidget);
    Navigator.of(tester.element(find.byType(AlertDialog))).pop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'no-match is distinct and Clear filter restores authenticated rows without listing',
    (tester) async {
      final f = await showBrowser(tester);
      f.api.gate!.complete();
      f.api.gate = null;
      await turns(tester);
      final before = f.api.calls;
      await tester.enterText(find.byType(TextField), 'absent');
      await tester.pumpAndSettle();
      expect(find.text('No matching files'), findsOneWidget);
      expect(find.text('This folder is empty'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, 'Clear filter'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      expect(find.text('Authenticated document.txt'), findsOneWidget);
      expect(f.api.calls, before);
    },
  );

  for (final failure in [
    ApiException(503, 'private diagnostic', 'secret response'),
    StateError('secret response'),
  ]) {
    testWidgets(
      'listing error redacts ${failure.runtimeType}, Retry recovers through loading',
      (tester) async {
        final f = await showBrowser(tester);
        f.api.failure = failure;
        f.api.gate!.complete();
        f.api.gate = null;
        await turns(tester);
        expect(find.text('Could not load this folder'), findsOneWidget);
        expect(find.textContaining('secret response'), findsNothing);
        expect(find.textContaining('private diagnostic'), findsNothing);
        expect(find.text('This folder is empty'), findsNothing);
        final before = f.api.calls;
        f.api.failure = null;
        f.api.gate = Completer<void>();
        await tester.tap(find.text('Retry'));
        await turns(tester);
        expect(f.api.calls, before + 1);
        expect(find.byKey(const ValueKey('browser-loading')), findsOneWidget);
        f.api.gate!.complete();
        f.api.gate = null;
        await turns(tester);
        expect(find.text('Authenticated document.txt'), findsOneWidget);
      },
    );
  }

  testWidgets('401 still signs out rather than presenting retry', (
    tester,
  ) async {
    final f = await showBrowser(tester);
    f.api.failure = ApiException(401, 'unauthorized', 'secret response');
    f.api.gate!.complete();
    f.api.gate = null;
    await turns(tester);
    expect(f.signouts(), 1);
    expect(find.text('Retry'), findsNothing);
    expect(find.textContaining('secret response'), findsNothing);
  });

  testWidgets(
    'refresh failure never presents retained rows as current or empty',
    (tester) async {
      final f = await showBrowser(tester);
      f.api.gate!.complete();
      f.api.gate = null;
      await turns(tester);
      expect(find.text('Authenticated document.txt'), findsOneWidget);
      f.api.failure = StateError('secret response');
      await tester.tap(find.byTooltip('Refresh'));
      await turns(tester);
      expect(find.text('Could not load this folder'), findsOneWidget);
      expect(find.text('Authenticated document.txt'), findsNothing);
      expect(find.text('This folder is empty'), findsNothing);
      expect(find.textContaining('secret response'), findsNothing);
    },
  );

  testWidgets(
    'close drains suspended listing and rejects late names and shortcuts',
    (tester) async {
      final f = await showBrowser(tester);
      f.session.search.close();
      var drained = false;
      final drain = f.operations
          .drain(f.session.handle)
          .then((_) => drained = true);
      await turns(tester);
      expect(drained, isFalse);
      final before = f.api.calls;
      await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      await tester.pump();
      expect(f.api.calls, before);
      f.api.gate!.complete();
      f.api.gate = null;
      await turns(tester);
      await drain;
      expect(drained, isTrue);
      expect(find.text('Authenticated document.txt'), findsNothing);
      expect(find.textContaining('secret response'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'narrow 200% $brightness static loading, empty, no-match and error scroll safely',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final f = await showBrowser(
          tester,
          width: 390,
          scale: 2,
          brightness: brightness,
          reducedMotion: true,
        );
        final loading = find.byKey(const ValueKey('browser-loading'));
        expect(loading, findsOneWidget);
        final scheme = Theme.of(tester.element(loading)).colorScheme;
        final bars = tester.widgetList<DecoratedBox>(
          find.descendant(of: loading, matching: find.byType(DecoratedBox)),
        );
        expect(bars, isNotEmpty);
        expect(
          bars.every(
            (b) =>
                (b.decoration as BoxDecoration).color ==
                scheme.surfaceContainerHighest,
          ),
          isTrue,
        );
        expect(find.bySemanticsLabel('Loading folder'), findsOneWidget);
        await tester.pumpAndSettle();
        expect(tester.binding.hasScheduledFrame, isFalse);
        f.api.files = [];
        f.api.gate!.complete();
        f.api.gate = null;
        await turns(tester);
        final create = find.widgetWithText(OutlinedButton, 'Create folder');
        await tester.ensureVisible(create);
        await tester.pumpAndSettle();
        expect(tester.getSize(create).height, greaterThanOrEqualTo(48));
        expect(
          tester.getSemantics(create).getSemanticsData().label,
          'Create folder',
        );
        await tester.enterText(find.byType(TextField), 'missing');
        await tester.pumpAndSettle();
        final clear = find.widgetWithText(FilledButton, 'Clear filter');
        await tester.ensureVisible(clear);
        await tester.pumpAndSettle();
        expect(tester.getSize(clear).height, greaterThanOrEqualTo(48));
        await tester.tap(clear);
        await tester.pumpAndSettle();
        f.api.failure = StateError('secret response');
        await tester.tap(find.byTooltip('Refresh'));
        await turns(tester);
        final retry = find.widgetWithText(FilledButton, 'Retry');
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        expect(tester.getSize(retry).height, greaterThanOrEqualTo(48));
        final icon = tester.widget<Icon>(find.byIcon(Icons.cloud_off));
        expect(icon.color, scheme.error);
        expect(find.textContaining('secret response'), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
    );
  }
}
