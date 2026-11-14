import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/storage_access.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AndroidAccess extends StorageAccess {
  @override
  bool get isAndroid => true;
}

class ControlledAccess extends StorageAccess {
  bool denied = true;
  StoragePermissionOutcome outcome = StoragePermissionOutcome.granted;
  int requests = 0;
  int settingsOpened = 0;
  Completer<StoragePermissionOutcome>? pending;
  @override
  bool get isAndroid => true;
  @override
  Future<bool> permissionRequired(String path) async => denied;
  @override
  Future<StoragePermissionOutcome> request() async {
    requests++;
    final result = pending == null ? outcome : await pending!.future;
    if (result == StoragePermissionOutcome.granted) denied = false;
    return result;
  }
  @override
  Future<void> openSettings() async {
    settingsOpened++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late ControlledAccess access;
  late SyncController sync;
  late SyncFolderConfig folder;
  var nativeCalls = 0;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('storage-access-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
    access = ControlledAccess();
    nativeCalls = 0;
    sync = SyncController(
        server: 'http://unused',
        token: 'private-token',
        handle: 0,
        api: ApiClient(baseUrl: 'http://unused'),
        storageAccess: access,
        syncRunner: (handle, request, progress) async {
          nativeCalls++;
          expect(request['localPath'], root.path);
          return {'uploaded': 1, 'downloaded': 0, 'conflicts': 0, 'errors': []};
        });
    folder = SyncFolderConfig(
        id: 'id',
        name: 'folder',
        localPath: root.path,
        remoteRootId: 'root',
        lastSync: '2026-01-01T00:00:00',
        lastReport: {'uploaded': 2, 'errors': []});
    sync.folders.add(folder);
  });
  tearDown(() async {
    sync.dispose();
    await root.delete(recursive: true);
  });

  test(
      'denied add and sync never admit remote/native work or report empty success',
      () async {
    expect(await sync.addFolder('${root.path}/other'), isFalse);
    expect(sync.folders, [folder]);
    expect(await sync.syncFolder(folder), isNull);
    expect(nativeCalls, 0);
    expect(access.requests, 0);
    expect(folder.storageAccessRequired, isTrue);
    expect(folder.lastError, contains('Grant access'));
    expect(folder.lastError, isNot(contains('private-token')));
    expect(folder.lastSync, '2026-01-01T00:00:00');
    await sync.syncAll();
    expect(sync.lastStatus, contains('had errors'));
  });

  test(
      'explicit grant rescans existing folder; revocation and denial preserve it',
      () async {
    await File('${root.path}/fixture.txt').writeAsString('local');
    await sync.syncFolder(folder);
    expect(await sync.grantStorageAccess(folder), isTrue);
    expect(nativeCalls, 1);
    expect(folder.storageAccessRequired, isFalse);
    expect(folder.lastError, isNull);
    expect(sync.folders.single.id, 'id');
    access.denied = true;
    access.outcome = StoragePermissionOutcome.denied;
    await sync.syncFolder(folder);
    expect(await sync.grantStorageAccess(folder), isFalse);
    expect(nativeCalls, 1);
    expect(folder.storageAccessRequired, isTrue);
    expect(folder.hasErrors, isTrue);
    expect(sync.lastPermissionOutcome, StoragePermissionOutcome.denied);
  });

  test(
      'accessible private directory needs no request; missing listing fails closed',
      () async {
    access.denied = false;
    expect(await sync.syncFolder(folder), isNotNull);
    expect(access.requests, 0);
    await root.delete(recursive: true);
    expect(await sync.syncFolder(folder), isNull);
    expect(nativeCalls, 1);
    expect(folder.lastError, contains('Cannot read'));
    await root.create();
  });

  test(
      'stop while settings are open drains and never admits retry or late grant',
      () async {
    access.pending = Completer<StoragePermissionOutcome>();
    final grant = sync.grantStorageAccess(folder);
    await Future<void>.delayed(Duration.zero);
    final drain = sync.stopAndDrain();
    access.pending!.complete(StoragePermissionOutcome.granted);
    expect(await grant, isFalse);
    await drain;
    expect(nativeCalls, 0);
    expect(await sync.grantStorageAccess(folder), isFalse);
    expect(access.requests, 1);
  });

  test('removing a folder while settings are open cancels its late retry',
      () async {
    access.pending = Completer<StoragePermissionOutcome>();
    final grant = sync.grantStorageAccess(folder);
    await Future<void>.delayed(Duration.zero);
    await sync.removeFolder(folder);
    access.pending!.complete(StoragePermissionOutcome.granted);
    expect(await grant, isFalse);
    expect(nativeCalls, 0);
    expect(sync.folders, isEmpty);
    expect(await sync.syncFolder(folder), isNull);
    expect(await File('${root.path}/sync/id.sqlite').exists(), isFalse);
  });

  test('channel checks refresh on every call and fail closed on absent status',
      () async {
    final calls = <MethodCall>[];
    bool? required = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StorageAccess.channel, (call) async {
      calls.add(call);
      if (call.method == 'status') return required;
      if (call.method == 'request') {
        return {'granted': false, 'outcome': 'permanently_denied'};
      }
      return root.path;
    });
    final android = AndroidAccess();
    await expectLater(
        android.check(root.path), throwsA(isA<StorageAccessException>()));
    required = false;
    await android.check(root.path);
    required = null;
    await expectLater(
        android.check(root.path), throwsA(isA<StorageAccessException>()));
    expect(calls.map((c) => c.method), ['status', 'status', 'status']);
    expect(await android.request(),
        StoragePermissionOutcome.permanentlyDenied);
    await android.openSettings();
    expect(calls.last.method, 'openSettings');
    expect(await android.privateFolder(), root.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(StorageAccess.channel, null);
  });

  testWidgets(
      'permission error offers explicit retry and private alternative without prompting',
      (tester) async {
    await tester.runAsync(() => sync.syncFolder(folder));
    await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));
    expect(find.text('Grant storage access and retry'), findsOneWidget);
    expect(access.requests, 0);
    await tester.tap(find.text('Grant storage access and retry'));
    await tester.pumpAndSettle();
    expect(find.text('Allow shared-storage sync?'), findsOneWidget);
    expect(access.requests, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(access.requests, 0);
    expect(nativeCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'permanent refusal offers the settings link and never re-prompts',
      (tester) async {
    access.outcome = StoragePermissionOutcome.permanentlyDenied;
    await tester.runAsync(() => sync.syncFolder(folder));
    await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));
    await tester.tap(find.text('Grant storage access and retry'));
    await tester.pumpAndSettle();
    expect(find.text('Allow shared-storage sync?'), findsOneWidget);
    await tester.tap(find.text('Continue to permission'));
    await tester.pumpAndSettle();
    expect(access.requests, 1);
    expect(find.textContaining('will not show the access prompt again'),
        findsOneWidget);
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    expect(access.settingsOpened, 1);
    // The next explicit attempt goes to settings instead of prompting again.
    // Clear the transient snack bars first so the retry button is hittable.
    ScaffoldMessenger.of(
            tester.element(find.text('Grant storage access and retry')))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grant storage access and retry'));
    await tester.pumpAndSettle();
    expect(find.text('Allow shared-storage sync?'), findsNothing);
    expect(access.requests, 1);
    expect(access.settingsOpened, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'retryable denial stays usable and offers no settings link',
      (tester) async {
    access.outcome = StoragePermissionOutcome.denied;
    await tester.runAsync(() => sync.syncFolder(folder));
    await tester.pumpWidget(MaterialApp(home: SyncPage(controller: sync)));
    await tester.tap(find.text('Grant storage access and retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue to permission'));
    await tester.pumpAndSettle();
    expect(access.requests, 1);
    expect(find.textContaining('Storage access was not granted'),
        findsOneWidget);
    expect(find.text('Open settings'), findsNothing);
    expect(access.settingsOpened, 0);
    // The app is still usable: the retry action and the private alternative
    // remain, and the folder was not silently treated as synchronized.
    expect(find.text('Grant storage access and retry'), findsOneWidget);
    expect(nativeCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });
}
