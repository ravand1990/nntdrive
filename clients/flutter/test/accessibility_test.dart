import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';

/// One favourite file at the account root.
class _RowApi extends ApiClient {
  _RowApi(this.file) : super(baseUrl: 'http://127.0.0.1:1', token: 'test-token');

  final RemoteFile file;

  @override
  Future<AccountInfo> me() async => AccountInfo(
      'account', 'a11y@example.invalid', 'Tester', false, null, 0);

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async =>
      parentId == null ? [file] : const [];
}

void main() {
  testWidgets('file rows expose their type and favourite state to TalkBack',
      (tester) async {
    final semantics = tester.ensureSemantics();
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
        () => bridge.generateAccountAsync('accessibility password'));
    final handle = (await tester.runAsync(() async =>
        bridge.unlock(jsonEncode(keys!['keyfile']),
            'accessibility password')['handle'] as int))!;
    const fileId = '7c9f1c40-1d11-4a58-8c31-2f9a1a0e4b11';
    final api = _RowApi(RemoteFile(fileId, null,
        bridge.sealName(handle, fileId, 'Notes.txt'), false, 12, true, 1, null));
    final operations = SessionOperations();
    await tester.pumpWidget(MaterialApp(
      home: FilesPage(
        session: Session(
          server: 'http://127.0.0.1:1',
          token: 'test-token',
          handle: handle,
          accountId: 'account',
          email: 'a11y@example.invalid',
          operations: operations,
        ),
        sync: SyncController(
          server: 'http://127.0.0.1:1',
          token: 'test-token',
          handle: handle,
          api: api,
        ),
        operations: operations,
        updates: UpdateChecks(check: () async => null, prompt: (_) async {}),
        themeMode: ThemeMode.light,
        onTheme: (_) {},
        onSignOut: () {},
        api: api,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Notes.txt'), findsOneWidget);
    expect(
      tester.getSemantics(find.byIcon(Icons.insert_drive_file_outlined)).label,
      contains('File'),
    );
    expect(
      tester.getSemantics(find.byIcon(Icons.star)).label,
      contains('Favourite'),
    );
    semantics.dispose();
  });

  testWidgets('the file list stays usable at 200% text scaling',
      (tester) async {
    final bridge = NativeBridge.instance;
    final keys = await tester.runAsync(
        () => bridge.generateAccountAsync('accessibility scale password'));
    final handle = (await tester.runAsync(() async =>
        bridge.unlock(jsonEncode(keys!['keyfile']),
            'accessibility scale password')['handle'] as int))!;
    const fileId = '7c9f1c40-1d11-4a58-8c31-2f9a1a0e4b12';
    final api = _RowApi(RemoteFile(fileId, null,
        bridge.sealName(handle, fileId, 'Quarterly report and notes.txt'),
        false, 123456, true, 1, null));
    final operations = SessionOperations();
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: FilesPage(
        session: Session(
          server: 'http://127.0.0.1:1',
          token: 'test-token',
          handle: handle,
          accountId: 'account',
          email: 'a11y@example.invalid',
          operations: operations,
        ),
        sync: SyncController(
          server: 'http://127.0.0.1:1',
          token: 'test-token',
          handle: handle,
          api: api,
        ),
        operations: operations,
        updates: UpdateChecks(check: () async => null, prompt: (_) async {}),
        themeMode: ThemeMode.light,
        onTheme: (_) {},
        onSignOut: () {},
        api: api,
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a doubled text size must not overflow the row layout');
    expect(find.text('Quarterly report and notes.txt'), findsOneWidget);
  });
}
