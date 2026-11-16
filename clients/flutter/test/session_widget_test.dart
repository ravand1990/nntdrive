import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/device_onboarding.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionApi extends ApiClient {
  SessionApi(this.accountId, this.sealed) : super(baseUrl: 'http://fixture');
  final String accountId;
  String sealed;
  static const node = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
  @override
  Future<AccountInfo> me() async => AccountInfo(accountId, 'test@example.invalid', '', false, null, 0)
    ..devices = [DeviceInfo('device', 'Device', 'linux', false, true)];
  @override
  Future<List<AccountRoot>> listRoots() async => [AccountRoot(rootId: 'root', kind: 'device',
    nodeId: node, nameEnc: sealed, deviceId: 'device')];
  @override
  Future<void> bootstrapRoot({required String kind, required String nodeId, required String nameEnc}) async {}
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async => parentId == null
    ? [RemoteFile(node, null, sealed, true, 0, false, 1, null)] : [];
  @override
  Future<void> renameFile(String id, String nameEnc,
      {required String? parentId, required List<RemoteFile> siblings}) async { sealed = nameEnc; }
}

void main() {
  testWidgets(
      'one session owns the controller until sign-out drains and locks it',
      (tester) async {
    final account = await tester.runAsync(() =>
        NativeBridge.instance.generateAccountAsync('session test password'));
    SharedPreferences.setMockInitialValues({
      'token': 'fixture-token',
      'keyfile': jsonEncode(account!['keyfile']),
      'accountId': account['account_id'],
      'email': 'test@example.invalid',
      'server': 'http://127.0.0.1:1',
      'updateAutoCheck': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final setupHandle = NativeBridge.instance.unlock(jsonEncode(account['keyfile']),
        'session test password')['handle'] as int;
    final api = SessionApi(account['account_id'] as String,
        NativeBridge.instance.sealName(setupHandle, SessionApi.node, 'Device'));
    NativeBridge.instance.lock(setupHandle);
    await tester.pumpWidget(NntDriveApp(prefs: prefs, apiFactory: (_, __) => api));
    await tester.pumpAndSettle();
    expect(find.byType(UnlockPage), findsOneWidget);
    expect(find.byType(FilesPage), findsNothing);
    await tester.enterText(find.byType(TextField), 'session test password');
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.runAsync(() async {
      for (var i = 0;
          i < 100 && (find.byType(DeviceOnboardingPage).evaluate().isEmpty ||
              tester.widgetList<TextField>(find.byType(TextField)).any((f) => f.enabled == false));
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(find.byType(DeviceOnboardingPage), findsOneWidget);
    expect(find.byType(FilesPage), findsNothing);
    await tester.enterText(find.byType(TextField), 'My test laptop');
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm device name'));
      for (var i = 0; i < 100 && (find.byType(FilesPage).evaluate().isEmpty ||
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    final files = tester.widget<FilesPage>(find.byType(FilesPage));
    final controller = files.sync;
    final handle = files.session.handle;
    // Theme rebuild and route navigation must not create a second scheduler.
    files.onTheme(ThemeMode.dark);
    await tester.pumpAndSettle();
    expect(
        identical(
            tester.widget<FilesPage>(find.byType(FilesPage)).sync, controller),
        isTrue);
    final active = Completer<void>();
    final operation = files.operations.run(handle, () => active.future);
    files.onSignOut();
    await tester.pump();
    expect(find.byType(FilesPage), findsOneWidget);
    expect(prefs.getString('token'), 'fixture-token');
    expect(
        NativeBridge.instance.sealName(
            handle, '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30', 'still draining'),
        isNotEmpty);
    await expectLater(
        files.operations.run(handle, () async {}), throwsStateError);
    active.complete();
    await operation;
    await tester.pumpAndSettle();
    expect(find.byType(FilesPage), findsNothing);
    expect(prefs.getString('token'), isNull);
    await controller.syncAll();
    expect(controller.syncing, isFalse);
    expect(
        () => NativeBridge.instance
            .sealName(handle, '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30', 'name'),
        throwsA(isA<NativeException>()));
    await tester.pump(const Duration(minutes: 6));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
