import 'package:flutter/material.dart';
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
    expect(find.text('Device offline · files remain available'), findsOneWidget);
    expect(find.text('Device revoked · files remain available'), findsOneWidget);
  });

  testWidgets('a failed bootstrap is shown with a retry action',
      (tester) async {
    final sync = _controller();
    addTearDown(sync.dispose);
    sync.rootsError = 'Sign in again to set up account spaces.';

    await _pumpPage(tester, sync);

    expect(find.text('Sign in again to set up account spaces.'), findsOneWidget);
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

  testWidgets('load bootstraps and stores the account roots', (tester) async {
    SharedPreferences.setMockInitialValues({});
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
    );
    addTearDown(sync.dispose);

    await sync.load();

    expect(loads, 1);
    expect(sync.accountRoots.map((r) => r.rootId), ['r1', 'r2']);
    expect(sync.rootsWarning, contains('device space'));
    expect(sync.rootsError, isNull);
    expect(sync.loaded, isTrue);
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
}
