import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/space_subscription.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

AccountRoot globalRoot({String nodeId = 'global-node'}) => AccountRoot(
      rootId: 'root-global',
      kind: 'global',
      nodeId: nodeId,
      nameEnc: 'sealed-global',
    );

AccountRoot deviceRoot({
  String nodeId = 'device-node',
  String name = 'Workstation',
}) =>
    AccountRoot(
      rootId: 'root-device',
      kind: 'device',
      nodeId: nodeId,
      nameEnc: 'sealed-device',
      deviceId: 'device-1',
      deviceName: name,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('space folder names', () {
    test('keeps an ordinary label', () {
      expect(safeSpaceFolderName('Global'), 'Global');
      expect(safeSpaceFolderName('  Workstation  '), 'Workstation');
      expect(safeSpaceFolderName('Büro-PC'), 'Büro-PC');
    });

    test('never yields a separator, a traversal or a reserved name', () {
      expect(safeSpaceFolderName('../../etc'), isNot(contains('/')));
      expect(safeSpaceFolderName('..'), isNull);
      expect(safeSpaceFolderName('   '), isNull);
      expect(safeSpaceFolderName('Work:station*?'), 'Work station');
      expect(safeSpaceFolderName('CON'), 'CON space');
      expect(safeSpaceFolderName('lpt\u00b9'), 'lpt\u00b9 space');
    });

    test('caps the component length', () {
      final name = safeSpaceFolderName('a' * 400)!;
      expect(name.runes.length, lessThanOrEqualTo(96));
    });

    test('deduplicates case-insensitively', () {
      expect(uniqueSpaceFolderName('Named', ['named']), 'Named (2)');
      expect(
          uniqueSpaceFolderName('Named', ['named', 'nAmEd (2)']), 'Named (3)');
      expect(uniqueSpaceFolderName('Named', []), 'Named');
      expect(uniqueSpaceFolderName('..', []), isNull);
    });

    test('refuses a folder name outside the spaces directory', () {
      expect(
        () => spaceDirectoryPath('/tmp/NNTDrive', '../escape'),
        throwsArgumentError,
      );
      expect(spaceDirectoryPath('/tmp/NNTDrive', 'Global'),
          p.join('/tmp/NNTDrive', 'Global'));
    });
  });

  group('subscribing spaces', () {
    late Directory scratch;
    late String documents;
    late List<Map<String, dynamic>> syncRequests;
    late List<SyncController> controllers;
    var nextSyncResult = <String, dynamic>{
      'uploaded': 0,
      'downloaded': 0,
      'conflicts': 0,
      'errors': <dynamic>[],
    };

    setUp(() async {
      scratch = await Directory.systemTemp.createTemp('space-subscription-');
      documents = p.join(scratch.path, 'documents');
      await Directory(documents).create(recursive: true);
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => call.method == 'getApplicationDocumentsDirectory'
            ? documents
            : p.join(scratch.path, 'support'),
      );
      syncRequests = [];
      controllers = [];
      nextSyncResult = {
        'uploaded': 0,
        'downloaded': 0,
        'conflicts': 0,
        'errors': <dynamic>[],
      };
    });

    tearDown(() async {
      for (final controller in controllers) {
        controller.dispose();
      }
      await scratch.delete(recursive: true);
    });

    SyncController controllerWith(List<AccountRoot> Function() roots) {
      final controller = SyncController(
        server: 'http://unused',
        token: 'private-token',
        handle: 0,
        api: ApiClient(baseUrl: 'http://unused'),
        rootsLoader: () async => AccountRootsResult(roots()),
        syncRunner: (handle, request, progress) async {
          syncRequests.add(request);
          return Map<String, dynamic>.from(nextSyncResult);
        },
      );
      controllers.add(controller);
      return controller;
    }

    test('Global is mirrored on this device without adding a folder', () async {
      final sync = controllerWith(() => [globalRoot(), deviceRoot()]);

      await sync.load();

      expect(sync.folders, hasLength(1));
      final folder = sync.folders.single;
      expect(folder.remoteRootId, 'global-node');
      expect(folder.name, 'Global');
      expect(p.dirname(folder.localPath), p.join(documents, 'NNTDrive'));
      expect(p.basename(folder.localPath), 'Global');
      expect(Directory(folder.localPath).existsSync(), isTrue);
      expect(syncRequests.single['remoteRootId'], 'global-node');
      expect(sync.lastStatus, 'Subscribed Global and synchronized it.');
      // Device spaces are not downloaded automatically.
      expect(sync.spaceSubscribed(deviceRoot()), isFalse);
    });

    test('a repeat refresh neither duplicates nor resyncs Global', () async {
      final sync = controllerWith(() => [globalRoot(), deviceRoot()]);
      await sync.load();
      expect(sync.folders, hasLength(1));

      await sync.refreshAccountRoots();

      expect(sync.folders, hasLength(1));
      expect(syncRequests, hasLength(1));
    });

    test('a device space can be subscribed on this device', () async {
      final sync = controllerWith(() => [globalRoot(), deviceRoot()]);
      await sync.load();

      expect(await sync.subscribeSpace(deviceRoot()), isTrue);

      final folder = sync.folderForSpace('device-node')!;
      expect(folder.name, 'Workstation');
      expect(p.dirname(folder.localPath), p.join(documents, 'NNTDrive'));
      expect(syncRequests.last['remoteRootId'], 'device-node');
      expect(Directory(folder.localPath).existsSync(), isTrue);
      expect(sync.folders, hasLength(2));
    });

    test('an unsafe device name stays inside the spaces directory', () async {
      final sync = controllerWith(
          () => [globalRoot(), deviceRoot(name: '../../Work:station')]);
      await sync.load();

      expect(await sync.subscribeSpace(deviceRoot(name: '../../Work:station')),
          isTrue);

      final folder = sync.folderForSpace('device-node')!;
      expect(
          p.isWithin(p.join(documents, 'NNTDrive'), folder.localPath), isTrue);
      expect(p.basename(folder.localPath), isNot(contains('/')));
      expect(p.basename(folder.localPath), isNot(contains(':')));
    });

    test('stopping Global keeps it stopped across a restart', () async {
      final first = controllerWith(() => [globalRoot()]);
      await first.load();
      expect(first.folders, hasLength(1));

      await first.unsubscribeSpace(globalRoot());
      expect(first.folders, isEmpty);
      expect(first.lastStatus, contains('no longer synchronized'));

      final second = controllerWith(() => [globalRoot()]);
      await second.load();
      expect(second.folders, isEmpty,
          reason: 'an explicit opt-out survives a restart');
      expect(syncRequests, hasLength(1));

      // Subscribing again is allowed and clears the opt-out.
      expect(await second.subscribeSpace(globalRoot()), isTrue);
      final third = controllerWith(() => [globalRoot()]);
      await third.load();
      expect(third.folders, hasLength(1));
    });

    test('a sync error is reported without dropping the subscription',
        () async {
      nextSyncResult = {
        'uploaded': 0,
        'downloaded': 0,
        'conflicts': 0,
        'errors': ['Upload of notes.txt failed'],
      };
      final sync = controllerWith(() => [globalRoot()]);

      await sync.load();

      expect(sync.folders, hasLength(1));
      expect(sync.lastStatus, 'Subscribed Global, but sync needs attention.');
      expect(sync.lastStatus, isNot(contains('private-token')));
    });

    test('unavailable roots create no folder and no sync', () async {
      final sync = SyncController(
        server: 'http://unused',
        token: 'private-token',
        handle: 0,
        api: ApiClient(baseUrl: 'http://unused'),
        rootsLoader: () async => throw ApiException(0, 'offline', 'offline'),
        syncRunner: (handle, request, progress) async {
          syncRequests.add(request);
          return {'uploaded': 0, 'downloaded': 0, 'conflicts': 0, 'errors': []};
        },
      );
      controllers.add(sync);

      await sync.load();

      expect(sync.folders, isEmpty);
      expect(syncRequests, isEmpty);
      expect(sync.rootsError, isNotNull);
    });
  });

  testWidgets('the spaces card offers sync and stop-syncing actions',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final sync = SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async => const AccountRootsResult([]),
    );
    addTearDown(sync.dispose);
    sync.accountRoots.addAll([globalRoot(), deviceRoot()]);
    sync.folders.add(SyncFolderConfig(
      id: 'folder-global',
      name: 'Global',
      localPath: '/tmp/global',
      remoteRootId: 'global-node',
    ));

    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));

    expect(find.text('Stop syncing'), findsOneWidget);
    expect(find.text('Sync to this device'), findsOneWidget);
  }, variant: TargetPlatformVariant.desktop());
}
