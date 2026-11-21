import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview_page.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The activity feed's Not synced action opens the sync page for one folder.
///
/// The controller is given a fake overview producer, so these tests exercise the
/// real navigation and folder scoping without the native engine or a server.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SyncController sync;
  late List<String> inspectedRoots;

  SyncFolderConfig folder(String id, String rootId, {bool enabled = true}) =>
      SyncFolderConfig(
        id: id,
        name: id,
        localPath: root.path,
        remoteRootId: rootId,
        enabled: enabled,
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('overview-link-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
    inspectedRoots = [];
    sync = SyncController(
      server: 'http://unused',
      token: 'private-token',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      overviewRunner: (handle, request, onPage, shouldContinue) async {
        inspectedRoots.add(request['remoteRootId'] as String);
        await onPage(const {'items': [], 'done': true});
      },
    );
  });

  tearDown(() async {
    sync.dispose();
    await root.delete(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'), null);
  });

  test('the overview lists one folder when a root id is named', () {
    final folders = [
      folder('a', 'root-a'),
      folder('b', 'root-b'),
      folder('c', 'root-c', enabled: false),
    ];
    expect(overviewFolders(folders, null).map((f) => f.id), ['a', 'b']);
    expect(overviewFolders(folders, 'root-b').map((f) => f.id), ['b']);
    expect(overviewFolders(folders, 'root-c'), isEmpty);
    expect(overviewFolders(folders, 'unknown'), isEmpty);
  });

  testWidgets('a deep link opens the Not synced screen for that folder', (
    tester,
  ) async {
    sync.folders.addAll([folder('a', 'root-a'), folder('b', 'root-b')]);
    await tester.pumpWidget(MaterialApp(
      home: SyncPage(controller: sync, openOverviewFor: 'root-b'),
    ));
    await tester.pump();
    // The overview resolves its journal path through a mocked platform channel,
    // so let real asynchronous work finish before checking the pushed route.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(SyncOverviewPage), findsOneWidget);
    // Only the folder the activity row named is inspected.
    expect(inspectedRoots, ['root-b']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('without a deep link the overview stays closed', (tester) async {
    sync.folders.add(folder('a', 'root-a'));
    await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));
    await tester.pumpAndSettle();
    expect(find.byType(SyncOverviewPage), findsNothing);
    expect(inspectedRoots, isEmpty);
  });

  testWidgets('a removed folder is reported instead of opening the overview', (
    tester,
  ) async {
    sync.folders.add(folder('a', 'root-a'));
    await tester.pumpWidget(MaterialApp(
      home: SyncPage(controller: sync, openOverviewFor: 'root-gone'),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(SyncOverviewPage), findsNothing);
    expect(inspectedRoots, isEmpty);
    expect(
      find.text('That folder is no longer a sync folder on this device.'),
      findsOneWidget,
    );
  });
}
