import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';

/// One folder at the account root and an empty folder inside it.
class _BrowserApi extends ApiClient {
  _BrowserApi() : super(baseUrl: 'http://127.0.0.1:1', token: 'test-token');

  RemoteFile? folder;
  int listCalls = 0;

  @override
  Future<AccountInfo> me() async => AccountInfo(
      'account', 'browser@example.invalid', 'Tester', false, null, 0);

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    listCalls++;
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
        updates: UpdateChecks(check: () async => null, prompt: (_) async {}),
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
