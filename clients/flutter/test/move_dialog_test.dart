import 'dart:convert';
import 'package:nntdrive/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/move_dialog.dart';

class FolderApi extends ApiClient {
  FolderApi() : super(baseUrl: 'http://unused');
  bool fail = false;
  RemoteFile? destination;
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    if (fail) throw StateError('private diagnostic');
    return [RemoteFile('source', null, 'unreadable', true, 0, false, 1, null),
      if (parentId == null && destination != null) destination!];
  }
}

void main() {
  testWidgets('move picker navigates encrypted folders and returns destination', (tester) async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('picker test password');
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), 'picker test password')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const id = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final api = FolderApi()..destination = RemoteFile(id, null,
      bridge.sealName(handle, id, 'Private folder'), true, 0, false, 1, null);
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(api: api, handle: handle,
        source: RemoteFile('source', null, 'opaque', true, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Private folder'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
    await tester.tap(find.byTooltip('Up'));
    await tester.pumpAndSettle();
    expect(find.text('Root'), findsOneWidget);
    await tester.tap(find.text('Private folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    expect(result?.parentId, id);
  });

  testWidgets('Copy picker distinguishes root selection from cancel and excludes current folder', (tester) async {
    final api = FolderApi();
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(api: api, handle: 0,
        source: RemoteFile('source', 'other-parent', 'opaque', false, 0, false, 1, null), copy: true));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Copy file to…'), findsOneWidget);
    await tester.tap(find.text('Copy here'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.parentId, isNull);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('move picker excludes source, disables current parent and cancels', (tester) async {
    final api = FolderApi();
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(api: api, handle: 0,
        source: RemoteFile('source', null, 'opaque', true, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Root'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    api.fail = true;
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Cannot read destination folders. Refresh and try again.'), findsOneWidget);
    expect(find.textContaining('private diagnostic'), findsNothing);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });
}
