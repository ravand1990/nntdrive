import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/device_onboarding.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/secure_keyfile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Publishes a keyfile for the same account but a newer epoch that this device
/// cannot open. The app must keep the local keyfile instead of locking out.
class _StalePublishApi extends ApiClient {
  _StalePublishApi(this.accountId, this.sealed) : super(baseUrl: 'http://fixture');

  final String accountId;
  String sealed;
  int keyfileCalls = 0;
  static const node = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';

  @override
  Future<Map<String, dynamic>?> keyfile() async {
    keyfileCalls++;
    return {
      'account_id': accountId,
      'epoch': 3,
      'wrapped_master_key': 'unreadable-wrapped-key-for-this-password',
      'kdf': {'salt': 'opaque'},
    };
  }

  @override
  Future<AccountInfo> me() async =>
      AccountInfo(accountId, 'test@example.invalid', '', false, null, 0);

  @override
  Future<List<AccountRoot>> listRoots() async => [
        AccountRoot(
            rootId: 'root',
            kind: 'device',
            nodeId: node,
            nameEnc: sealed,
            deviceId: 'device'),
      ];

  @override
  Future<void> bootstrapRoot(
      {required String kind,
      required String nodeId,
      required String nameEnc}) async {}

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async =>
      parentId == null
          ? [RemoteFile(node, null, sealed, true, 0, false, 1, null)]
          : [];

  @override
  Future<void> renameFile(String id, String nameEnc,
      {required String? parentId, required List<RemoteFile> siblings}) async {
    sealed = nameEnc;
  }
}

void main() {
  testWidgets('unlock fetches the published keyfile and survives an unreadable one',
      (tester) async {
    const password = 'keyfile refresh test password';
    final account = await tester.runAsync(
        () => NativeBridge.instance.generateAccountAsync(password));
    final storedKeyfile = jsonEncode(account!['keyfile']);
    SharedPreferences.setMockInitialValues({
      'token': 'fixture-token',
      'keyfile': storedKeyfile,
      'accountId': account['account_id'],
      'email': 'test@example.invalid',
      'server': 'http://127.0.0.1:1',
      'updateAutoCheck': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final setupHandle =
        NativeBridge.instance.unlock(storedKeyfile, password)['handle'] as int;
    final api = _StalePublishApi(
        account['account_id'] as String,
        NativeBridge.instance
            .sealName(setupHandle, _StalePublishApi.node, 'Device'));
    NativeBridge.instance.lock(setupHandle);

    await tester.pumpWidget(NntDriveApp(
      prefs: prefs,
      apiFactory: (_, __) => api,
      // A keyfile vault without a platform store uses the preferences fallback,
      // which keeps this test independent of the host keyring.
      keyfileVault: KeyfileVault(prefs: prefs),
    ));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), password);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.runAsync(() async {
      for (var i = 0;
          i < 150 && find.byType(DeviceOnboardingPage).evaluate().isEmpty;
          i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();

    expect(api.keyfileCalls, 1, reason: 'unlock asks the server for its keyfile');
    expect(find.byType(DeviceOnboardingPage), findsOneWidget);
    // The unreadable published epoch was refused; the local keyfile still won.
    final saved = jsonDecode(prefs.getString('keyfile')!) as Map<String, dynamic>;
    expect(saved['epoch'], 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
