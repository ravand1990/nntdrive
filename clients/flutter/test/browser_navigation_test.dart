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
import 'package:nntdrive/session_navigation.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:nntdrive/activity_page.dart';
import 'package:nntdrive/search_page.dart';
import 'package:nntdrive/trash_page.dart';

/// One folder at the account root and an empty folder inside it.
class _BrowserApi extends ApiClient {
  _BrowserApi() : super(baseUrl: 'http://127.0.0.1:1', token: 'test-token');

  RemoteFile? folder;
  int listCalls = 0;
  final parents = <String?>[];
  Object? rootsError;
  Object? filesError;
  bool filesErrorOnlyInFolder = false;
  Completer<void>? rootsGate;
  int rootsCalls = 0;

  @override
  Future<List<AccountRoot>> listRoots() async {
    rootsCalls++;
    await rootsGate?.future;
    if (rootsError != null) throw rootsError!;
    return [
      if (folder != null) AccountRoot(rootId: 'global-root', kind: 'global',
          nodeId: folder!.id, nameEnc: folder!.nameEnc),
    ];
  }

  @override
  Future<List<DeviceInfo>> devices() async => [];

  @override
  Future<TrashListing> trash() async => TrashListing(30, []);

  @override
  Future<AccountInfo> me() async => AccountInfo(
      'account', 'browser@example.invalid', 'Tester', false, null, 0);

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    listCalls++;
    parents.add(parentId);
    if (filesError != null && (!filesErrorOnlyInFolder || parentId != null)) {
      throw filesError!;
    }
    if (parentId == null) return [if (folder != null) folder!];
    return const [];
  }
}

/// The page's own back scope; `find.byType` cannot match a generic widget type.
PopScope<Object?> browserBackScope(WidgetTester tester) => tester
    .widgetList<PopScope<Object?>>(
        find.byWidgetPredicate((widget) => widget is PopScope<Object?>))
    .first;

/// Android system back arrives as a `flutter/navigation` popRoute message.
Future<void> systemBack(WidgetTester tester) async {
  final message =
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute'));
  await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage('flutter/navigation', message, (_) {});
  await tester.pumpAndSettle();
}

void main() {
  // Arm failures only after the real FilesPage's initial listing.
  Future<({_BrowserApi api, int Function() signOuts})>
      showNavigation(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(() => bridge.generateAccountAsync('navigation regression'));
    final handle = bridge.unlock(jsonEncode(keys!['keyfile']), 'navigation regression')['handle'] as int;
    const id = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final api = _BrowserApi()..folder = RemoteFile(id, null,
      bridge.sealName(handle, id, 'Authenticated Global'), true, 0, false, 1, null);
    final operations = SessionOperations();
    final session = Session(server: api.baseUrl, token: 'fixture', handle: handle,
      accountId: 'account', email: 'browser@example.invalid', operations: operations);
    final sync = SyncController(server: api.baseUrl, token: 'fixture', handle: handle, api: api);
    var signOuts = 0;
    await tester.pumpWidget(MaterialApp(home: FilesPage(
      session: session, sync: sync, operations: operations, api: api,
      updates: UpdateChecks(check: () async => null, prompt: (_) async => true),
      themeMode: ThemeMode.light, onTheme: (_) {}, onSignOut: () => signOuts++,
    )));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      session.search.close();
      await operations.drain(handle);
      sync.dispose();
      bridge.lock(handle);
    });
    return (api: api, signOuts: () => signOuts);
  }

  for (final source in ['listRoots', 'preliminary listFiles']) {
    for (final status in [401, 500]) {
      testWidgets('Global $source $status preserves auth handling and redaction', (tester) async {
        final fixture = await showNavigation(tester);
        final error = ApiException(status, 'private-code', 'private server diagnostic');
        if (source == 'listRoots') {
          fixture.api.rootsError = error;
        } else {
          fixture.api.filesError = error;
        }
        final calls = fixture.api.listCalls;
        await tester.tap(find.byKey(const ValueKey('navigation-global')));
        await tester.pumpAndSettle();
        expect(fixture.api.rootsCalls, 1);
        expect(fixture.api.listCalls, calls + (source == 'listRoots' ? 0 : 1));
        expect(fixture.signOuts(), status == 401 ? 1 : 0);
        expect(find.text('My files'), findsOneWidget);
        expect(find.text('Location unavailable. Refresh and retry.'),
            status == 401 ? findsNothing : findsOneWidget);
        expect(find.textContaining('private'), findsNothing);
      });
    }
  }

  for (final status in [401, 500]) {
    testWidgets('Global final refresh $status retains existing auth handling and redaction', (tester) async {
      final fixture = await showNavigation(tester);
      fixture.api
        ..filesErrorOnlyInFolder = true
        ..filesError = ApiException(status, 'private-code', 'private server diagnostic');
      await tester.tap(find.byKey(const ValueKey('navigation-global')));
      await tester.pumpAndSettle();
      expect(fixture.api.parents.last, fixture.api.folder!.id);
      expect(fixture.signOuts(), status == 401 ? 1 : 0);
      expect(find.text('Folder unavailable. Refresh and retry.'),
          status == 401 ? findsNothing : findsOneWidget);
      expect(find.text('Location unavailable. Refresh and retry.'), findsNothing);
      expect(find.textContaining('private'), findsNothing);
    });
  }

  for (final destination in [SessionDestination.devices, SessionDestination.activity]) {
    testWidgets('suspended Global is superseded by ${destination.name}', (tester) async {
      final fixture = await showNavigation(tester);
      final gate = Completer<void>();
      fixture.api.rootsGate = gate;
      await tester.tap(find.byKey(const ValueKey('navigation-global')));
      await tester.pump();
      expect(fixture.api.rootsCalls, 1);
      final calls = fixture.api.listCalls;
      await tester.tap(find.byKey(ValueKey('navigation-${destination.name}')));
      await tester.pumpAndSettle();
      // Release even on old code so session drain never hangs in teardown.
      final latestWasAdmitted = destination == SessionDestination.devices
          ? fixture.api.listCalls > calls
          : find.byType(ActivityPage).evaluate().isNotEmpty;
      gate.complete();
      await tester.pumpAndSettle();
      if (destination == SessionDestination.activity) {
        expect(find.byType(ActivityPage), findsOneWidget);
        Navigator.of(tester.element(find.byType(ActivityPage))).pop();
        await tester.pumpAndSettle();
      }
      expect(latestWasAdmitted, isTrue,
          reason: 'latest selection must be admitted before Global resumes');
      expect(find.text('My files'), findsOneWidget);
      expect(browserBackScope(tester).canPop, isTrue);
      expect(fixture.api.parents.where((id) => id == fixture.api.folder!.id), isEmpty,
          reason: 'stale Global must never commit or refresh its destination');
      expect(fixture.signOuts(), 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final tooltip in ['Sync folders', 'Trash', 'Account']) {
    testWidgets('app-bar $tooltip supersedes suspended Global', (tester) async {
      final fixture = await showNavigation(tester);
      final gate = Completer<void>();
      fixture.api.rootsGate = gate;
      await tester.tap(find.byKey(const ValueKey('navigation-global')));
      await tester.pump();
      expect(fixture.api.rootsCalls, 1);
      await tester.tap(find.byTooltip(tooltip));
      await tester.pumpAndSettle();
      gate.complete();
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.byType(FilesPage, skipOffstage: false))).pop();
      await tester.pumpAndSettle();
      expect(find.text('My files'), findsOneWidget);
      expect(fixture.api.parents.where((id) => id == fixture.api.folder!.id), isEmpty);
      expect(browserBackScope(tester).canPop, isTrue);
    });
  }

  testWidgets('production browser chrome uses real roots and existing route owners', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(() => bridge.generateAccountAsync('navigation fixture'));
    final handle = bridge.unlock(jsonEncode(keys!['keyfile']), 'navigation fixture')['handle'] as int;
    const id = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final api = _BrowserApi()..folder = RemoteFile(id, null,
      bridge.sealName(handle, id, 'Authenticated Global'), true, 0, false, 1, null);
    final operations = SessionOperations();
    final session = Session(server: api.baseUrl, token: 'fixture', handle: handle,
      accountId: 'account', email: 'browser@example.invalid', operations: operations);
    final sync = SyncController(server: api.baseUrl, token: 'fixture', handle: handle, api: api);
    await tester.pumpWidget(MaterialApp(home: FilesPage(
      session: session, sync: sync, operations: operations, api: api,
      updates: UpdateChecks(check: () async => null, prompt: (_) async => true),
      themeMode: ThemeMode.light, onTheme: (_) {}, onSignOut: () {},
    )));
    await tester.pumpAndSettle();
    final pageState = tester.state(find.byType(FilesPage));
    Future<void> select(SessionDestination destination) async {
      await tester.tap(find.byKey(ValueKey('navigation-${destination.name}')));
      await tester.pumpAndSettle();
    }
    Future<void> back() async {
      Navigator.of(tester.element(find.byType(FilesPage, skipOffstage: false))).pop();
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.byType(TextField), 'does not match');
    await select(SessionDestination.global);
    expect(api.parents.last, id);
    expect(find.text('Authenticated Global'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    expect(browserBackScope(tester).canPop, isFalse);
    await select(SessionDestination.devices);
    expect(api.parents.last, isNull);
    expect(find.text('My files'), findsOneWidget);
    expect(find.text('Authenticated Global'), findsOneWidget);
    expect(browserBackScope(tester).canPop, isTrue);
    await select(SessionDestination.sync);
    expect(tester.widget<SyncPage>(find.byType(SyncPage)).controller, same(sync));
    await back();
    await select(SessionDestination.activity);
    final log = tester.widget<ActivityPage>(find.byType(ActivityPage)).log;
    await back();
    await select(SessionDestination.activity);
    expect(tester.widget<ActivityPage>(find.byType(ActivityPage)).log, same(log));
    await back();
    await tester.runAsync(() => tester.tap(find.byKey(const ValueKey('navigation-search'))));
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      if (!session.search.building) break;
    }
    await tester.pumpAndSettle();
    expect(tester.widget<AccountSearchPage>(find.byType(AccountSearchPage)).index, same(session.search));
    await back();
    await select(SessionDestination.trash);
    expect(find.byType(TrashPage), findsOneWidget);
    await back();
    await select(SessionDestination.settings);
    expect(find.text('Storage usage'), findsOneWidget);
    expect(find.text('browser@example.invalid'), findsOneWidget);
    await back();
    await select(SessionDestination.manageDevices);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    // An unauthenticated label must not turn the old listing into a Global
    // destination, nor leak the native failure into presentation.
    api.folder = RemoteFile(id, null, 'invalid-envelope', true, 0, false, 1, null);
    await select(SessionDestination.global);
    expect(find.text('My files'), findsOneWidget);
    expect(find.text('Location unavailable. Refresh and retry.'), findsOneWidget);
    expect(browserBackScope(tester).canPop, isTrue);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    for (final width in [1024.0, 768.0, 390.0, 1440.0]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(FilesPage)), same(pageState));
      final page = tester.widget<FilesPage>(find.byType(FilesPage));
      expect(page.session, same(session));
      expect(page.sync, same(sync));
      expect(page.operations, same(operations));
    }
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    tester.view.physicalSize = const Size(390, 900);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-compact')), findsOneWidget);
    expect(tester.state(find.byType(FilesPage)), same(pageState));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.search.close();
    await operations.drain(handle);
    sync.dispose();
    bridge.lock(handle);
  });

  testWidgets('account menu reaches read-only storage on a small window', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _BrowserApi();
    final operations = SessionOperations();
    final session = Session(server: api.baseUrl, token: 'fixture', handle: 0,
      accountId: 'fixture', email: 'fixture@example.invalid', operations: operations);
    final sync = SyncController(server: api.baseUrl, token: 'fixture', handle: 0, api: api);
    await tester.pumpWidget(MaterialApp(home: FilesPage(session: session,
      sync: sync, operations: operations,
      updates: UpdateChecks(check: () async => null, prompt: (_) async => true),
      themeMode: ThemeMode.light, onTheme: (_) {}, onSignOut: () {}, api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Storage usage'));
    await tester.runAsync(() => tester.tap(find.text('Storage usage')));
    // Wait on the always-built toolbar: the account progress row can be below
    // this small viewport and therefore absent from the lazy ListView.
    for (var i = 0; i < 500; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(const Duration(milliseconds: 20));
      final refresh = find.byWidgetPredicate((widget) =>
          widget is IconButton && widget.tooltip == 'Refresh storage usage');
      if (session.search.closed || (refresh.evaluate().isNotEmpty &&
          tester.widget<IconButton>(refresh).onPressed != null)) {
        break;
      }
    }
    expect(find.byType(LinearProgressIndicator), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('This device · indexed offline cache'), findsOneWidget);
    expect(find.text('Clear unpinned cache'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Live files · logical bytes'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Live files · logical bytes'), findsOneWidget);
    // The deliberately invalid handle closes this fixture's session. Closing
    // must not be overwritten by a late account-refresh failure.
    expect(session.search.closed, isTrue);
    await tester.scrollUntilVisible(
      find.text('Session closed. Unlock again to view storage.'),
      100,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Session closed. Unlock again to view storage.'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    session.search.close();
    await operations.drain(0);
    sync.dispose();
  });

  testWidgets('system back leaves one folder instead of exiting the account',
      (tester) async {
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
        () => bridge.generateAccountAsync('browser navigation password'));
    final handle = (await tester.runAsync(() async =>
        bridge.unlock(jsonEncode(keys!['keyfile']),
            'browser navigation password')['handle'] as int))!;
    const folderId = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final api = _BrowserApi()
      ..folder = RemoteFile(folderId, null,
          bridge.sealName(handle, folderId, 'Docs'), true, 0, false, 1, null);
    final operations = SessionOperations();
    final sync = SyncController(
      server: 'http://127.0.0.1:1',
      token: 'test-token',
      handle: handle,
      api: api,
    );

    await tester.pumpWidget(MaterialApp(
      home: FilesPage(
        session: Session(
          server: 'http://127.0.0.1:1',
          token: 'test-token',
          handle: handle,
          accountId: 'account',
          email: 'browser@example.invalid',
          operations: operations,
        ),
        sync: sync,
        operations: operations,
        updates: UpdateChecks(check: () async => null, prompt: (_) async => true),
        themeMode: ThemeMode.light,
        onTheme: (_) {},
        onSignOut: () {},
        api: api,
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('My files'), findsOneWidget);
    // The account root stays poppable, so back can still leave the app.
    expect(browserBackScope(tester).canPop, isTrue);

    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    expect(find.text('Docs'), findsOneWidget);
    expect(find.byTooltip('Up one folder'), findsOneWidget);
    expect(browserBackScope(tester).canPop, isFalse,
        reason: 'back must be handled by the folder trail, not the route');

    await systemBack(tester);
    expect(find.text('My files'), findsOneWidget);
    expect(find.byTooltip('Up one folder'), findsNothing);
    expect(api.listCalls, greaterThanOrEqualTo(3));
    expect(browserBackScope(tester).canPop, isTrue);
  });
}
