import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

SyncController _controller() => SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async => const AccountRootsResult([]),
    );

/// The spaces card sits after the folder list; a tall surface keeps it built
/// without depending on lazily built ListView children.
Future<void> _pumpPage(WidgetTester tester, SyncController sync) async {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));
}

void main() {
  testWidgets('account spaces show Global and device presence markers',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([
      AccountRoot(rootId: 'r1', kind: 'global', nodeId: 'n1', nameEnc: 'x'),
      AccountRoot(
          rootId: 'r2',
          kind: 'device',
          nodeId: 'n2',
          nameEnc: 'x',
          deviceName: 'Workstation',
          stale: true),
      AccountRoot(
          rootId: 'r3',
          kind: 'device',
          nodeId: 'n3',
          nameEnc: 'x',
          deviceName: 'Old tablet',
          deviceRevoked: true),
    ]);

    await _pumpPage(tester, sync);

    expect(find.text('Account spaces'), findsOneWidget);
    expect(find.text('Shared with every device'), findsOneWidget);
    expect(find.text('Workstation'),
        findsOneWidget); // a stale device stays listed
    expect(
        find.text('Device offline · files remain available'), findsOneWidget);
    expect(
        find.text('Device revoked · files remain available'), findsOneWidget);
  });

  testWidgets('a failed bootstrap is shown with a retry action',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.rootsError = 'Sign in again to set up account spaces.';

    await _pumpPage(tester, sync);

    expect(
        find.text('Sign in again to set up account spaces.'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('loading accounts spaces is not reported as "no spaces yet"',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.rootsLoading = true;

    await _pumpPage(tester, sync);

    expect(
        find.text(
            'No spaces yet. They are created automatically the next time this client signs in.'),
        findsNothing);
  });

  // Real local folder creation needs the normal event loop, so this is a plain
  // test rather than a widget test with its fake-async zone.
  test('load bootstraps and stores the account roots', () async {
    SharedPreferences.setMockInitialValues({});
    final scratch = await Directory.systemTemp.createTemp('spaces-widget-');
    addTearDown(() => scratch.delete(recursive: true));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => scratch.path);
    var loads = 0;
    final sync = SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async {
        loads++;
        return AccountRootsResult([
          AccountRoot(rootId: 'r1', kind: 'global', nodeId: 'n1', nameEnc: 'x'),
          AccountRoot(
              rootId: 'r2',
              kind: 'device',
              nodeId: 'n2',
              nameEnc: 'x',
              deviceName: 'Workstation'),
        ], warning: 'This sign-in cannot create a device space.');
      },
      syncRunner: (handle, request, progress) async =>
          {'uploaded': 0, 'downloaded': 0, 'conflicts': 0, 'errors': []},
    );
    addTearDown(sync.dispose);

    await sync.load();
    expect(loads, 1);
    expect(sync.accountRoots.map((r) => r.rootId), ['r1', 'r2']);
    expect(sync.rootsWarning, contains('device space'));
    expect(sync.rootsError, isNull);
    expect(sync.loaded, isTrue);
    // Global is mirrored on this device; the other device's space is not.
    expect(sync.folders, hasLength(1));
    expect(sync.folders.single.remoteRootId, 'n1');
    expect(sync.spaceSubscribed(sync.accountRoots.last), isFalse);
  });

  testWidgets('a bootstrap failure does not fail loading the sync page',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sync = SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async => throw ApiException(
          0, 'network', 'Could not reach the server to set up account spaces.'),
    );
    addTearDown(sync.dispose);

    await sync.load();

    expect(sync.loaded, isTrue);
    expect(sync.rootsError, contains('Could not reach the server'));
    expect(sync.accountRoots, isEmpty);
  });

  testWidgets('a partly excluded Global folder is marked as not fully shared',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([
      AccountRoot(rootId: 'r1', kind: 'global', nodeId: 'n1', nameEnc: 'x'),
      AccountRoot(
          rootId: 'r2',
          kind: 'device',
          nodeId: 'n2',
          nameEnc: 'x',
          deviceName: 'Workstation'),
    ]);
    sync.folders.addAll([
      SyncFolderConfig(
          id: 'f1',
          name: 'Global',
          localPath: '/library/Global',
          remoteRootId: 'n1',
          excluded: const ['photos']),
      SyncFolderConfig(
          id: 'f2',
          name: 'Workstation',
          localPath: '/library/Workstation',
          remoteRootId: 'n2',
          excluded: const ['videos']),
    ]);

    await _pumpPage(tester, sync);

    // Only the shared space is marked; a device space exclusion is local.
    expect(find.text('Not fully shared: 1 excluded folder'), findsOneWidget);
    expect(find.text('Not fully shared: 2 excluded folders'), findsNothing);
  });

  testWidgets('the selective-sync dialog warns when Global has exclusions',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([
      AccountRoot(rootId: 'r1', kind: 'global', nodeId: 'n1', nameEnc: 'x'),
    ]);
    sync.folders.add(SyncFolderConfig(
        id: 'f1',
        name: 'Global',
        localPath: '/library/Global',
        remoteRootId: 'n1',
        excluded: const ['photos']));

    await _pumpPage(tester, sync);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selective sync…'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Global is shared with every device'),
        findsOneWidget);
    expect(find.textContaining('1 excluded folder'), findsNWidgets(2));
    expect(find.textContaining('Excluded paths stop synchronizing'),
        findsOneWidget);
    expect(find.text('Not fully shared: 1 excluded folder'), findsOneWidget);
    expect(find.text('Everything in this folder is synchronized.'),
        findsNothing);

    // Removing the exclusion removes the warning straight away.
    tester.widget<InputChip>(find.byType(InputChip)).onDeleted!();
    await tester.pumpAndSettle();
    expect(find.textContaining('Global is shared with every device'),
        findsNothing);
    expect(find.textContaining('Excluded paths stop synchronizing'),
        findsNothing);
    // The folder card still shows the saved exclusion until it is saved.
    expect(find.text('Not fully shared: 1 excluded folder'), findsOneWidget);
    expect(find.text('Everything in this folder is synchronized.'),
        findsOneWidget);
  });

  testWidgets('the selective-sync dialog stays silent for a device space',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([
      AccountRoot(
          rootId: 'r2',
          kind: 'device',
          nodeId: 'n2',
          nameEnc: 'x',
          deviceName: 'Workstation'),
    ]);
    sync.folders.add(SyncFolderConfig(
        id: 'f2',
        name: 'Workstation',
        localPath: '/library/Workstation',
        remoteRootId: 'n2',
        excluded: const ['videos']));

    await _pumpPage(tester, sync);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selective sync…'));
    await tester.pumpAndSettle();

    expect(find.text('Everything in this folder is synchronized.'),
        findsNothing);
    expect(find.textContaining('Global is shared with every device'),
        findsNothing);
  });
}
