import 'dart:async';
import 'dart:convert';
import 'package:nntdrive/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/move_dialog.dart';
import 'package:nntdrive/session_operations.dart';

class FolderApi extends ApiClient {
  FolderApi() : super(baseUrl: 'http://unused');
  bool fail = false;
  RemoteFile? destination;
  @override
  Future<List<AccountRoot>> listRoots() async => const [];
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    if (fail) throw StateError('private diagnostic');
    return [RemoteFile('source', null, 'unreadable', true, 0, false, 1, null),
      if (parentId == null && destination != null) destination!];
  }
}

class BlockingFolderApi extends ApiClient {
  BlockingFolderApi() : super(baseUrl: 'http://unused');
  final listing = Completer<List<RemoteFile>>();
  int requests = 0;
  @override
  Future<List<AccountRoot>> listRoots() async => const [];
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) {
    requests++;
    return listing.future;
  }
}

/// A namespace with two fixed spaces and one folder inside Global.
class SpaceApi extends ApiClient {
  SpaceApi(this.files, this.roots) : super(baseUrl: 'http://unused');
  final Map<String?, List<RemoteFile>> files;
  final List<AccountRoot> roots;
  bool failRoots = false;
  @override
  Future<List<AccountRoot>> listRoots() async {
    if (failRoots) throw StateError('private roots diagnostic');
    return roots;
  }

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async =>
      files[parentId] ?? const [];
}

void main() {
  testWidgets('picker drains a pending listing, not an idle dialog, and rejects late loads', (tester) async {
    final api = BlockingFolderApi();
    final operations = SessionOperations();
    const handle = 42;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () {
      showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(
        api: api, handle: handle, operations: operations,
        source: RemoteFile('source', null, 'opaque', true, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(api.requests, 1);
    var drained = false;
    final drain = operations.drain(handle).then((_) => drained = true);
    await tester.pump();
    expect(drained, isFalse);
    api.listing.complete([]);
    await tester.pumpAndSettle();
    await drain;
    expect(drained, isTrue);
    expect(find.byType(MoveDialog), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(api.requests, 1);
    expect(find.text('Cannot read destination folders. Refresh and try again.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

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

  testWidgets('moving out of Global labels each space and asks before leaving', (tester) async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('space picker password');
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), 'space picker password')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const globalId = '6f0d3e3c-0c59-4a0b-9f07-0f7e4a1f7a10';
    const deviceId = '8a4c2b1d-3e5f-4a6b-8c9d-0e1f2a3b4c5d';
    RemoteFile folder(String id, String name) => RemoteFile(id, null,
      bridge.sealName(handle, id, name), true, 0, false, 1, null);
    final api = SpaceApi(
      {null: [folder(globalId, 'Global'), folder(deviceId, 'Laptop')], globalId: const [], deviceId: const []},
      [
        AccountRoot(rootId: 'r1', kind: 'global', nodeId: globalId, nameEnc: ''),
        AccountRoot(rootId: 'r2', kind: 'device', nodeId: deviceId, nameEnc: '',
          deviceName: 'Laptop'),
      ],
    );
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(
        api: api, handle: handle, sourceSpaceRootId: globalId,
        source: RemoteFile('file1', globalId, 'opaque', false, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Global space · synced on every device'), findsOneWidget);
    expect(find.text('Device space · on demand on this device'), findsOneWidget);
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    expect(find.text('Move out of Global?'), findsOneWidget);
    expect(find.textContaining('stops syncing automatically'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.byType(MoveDialog), findsOneWidget);
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Move'));
    await tester.pumpAndSettle();
    expect(result?.parentId, deviceId);
  });

  testWidgets('a move that stays inside Global is not confirmed', (tester) async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('space picker password two');
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), 'space picker password two')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const globalId = '1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f';
    const docsId = '2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f';
    RemoteFile folder(String id, String name) => RemoteFile(id, null,
      bridge.sealName(handle, id, name), true, 0, false, 1, null);
    final api = SpaceApi(
      {
        null: [folder(globalId, 'Global')],
        globalId: [RemoteFile(docsId, globalId, bridge.sealName(handle, docsId, 'Docs'), true, 0, false, 1, null)],
        docsId: const [],
      },
      [AccountRoot(rootId: 'r1', kind: 'global', nodeId: globalId, nameEnc: '')],
    );
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(
        api: api, handle: handle, sourceSpaceRootId: globalId,
        source: RemoteFile('file1', globalId, 'opaque', false, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Global'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Docs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    expect(find.text('Move out of Global?'), findsNothing);
    expect(result?.parentId, docsId);
  });

  testWidgets('copy keeps the original in Global, so it is not confirmed', (tester) async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('space picker password three');
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), 'space picker password three')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const globalId = '3d4e5f6a-7b8c-4d9e-8f0a-2b3c4d5e6f70';
    const deviceId = '4e5f6a7b-8c9d-4e0f-9a1b-3c4d5e6f7a81';
    RemoteFile folder(String id, String name) => RemoteFile(id, null,
      bridge.sealName(handle, id, name), true, 0, false, 1, null);
    final api = SpaceApi(
      {null: [folder(globalId, 'Global'), folder(deviceId, 'Laptop')]},
      [
        AccountRoot(rootId: 'r1', kind: 'global', nodeId: globalId, nameEnc: ''),
        AccountRoot(rootId: 'r2', kind: 'device', nodeId: deviceId, nameEnc: '',
          deviceName: 'Laptop'),
      ],
    );
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(
        api: api, handle: handle, copy: true, sourceSpaceRootId: globalId,
        source: RemoteFile('file1', globalId, 'opaque', false, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy here'));
    await tester.pumpAndSettle();
    expect(find.text('Move out of Global?'), findsNothing);
    expect(result?.parentId, deviceId);
  });

  testWidgets('an unreachable space list never blocks a move or shows its error', (tester) async {
    final bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('space picker password four');
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), 'space picker password four')['handle'] as int;
    addTearDown(() => bridge.lock(handle));
    const globalId = '5f6a7b8c-9d0e-4f1a-8b2c-4d5e6f7a8b92';
    const deviceId = '6a7b8c9d-0e1f-4a2b-9c3d-5e6f7a8b9ca3';
    RemoteFile folder(String id, String name) => RemoteFile(id, null,
      bridge.sealName(handle, id, name), true, 0, false, 1, null);
    final api = SpaceApi(
      {null: [folder(globalId, 'Global'), folder(deviceId, 'Laptop')]},
      [AccountRoot(rootId: 'r1', kind: 'global', nodeId: globalId, nameEnc: '')],
    )..failRoots = true;
    MoveDestination? result;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => TextButton(onPressed: () async {
      result = await showDialog<MoveDestination>(context: context, builder: (_) => MoveDialog(
        api: api, handle: handle, sourceSpaceRootId: globalId,
        source: RemoteFile('file1', globalId, 'opaque', false, 0, false, 1, null)));
    }, child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Global space ·'), findsNothing);
    expect(find.textContaining('private roots diagnostic'), findsNothing);
    await tester.tap(find.text('Laptop'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move here'));
    await tester.pumpAndSettle();
    expect(result?.parentId, deviceId);
  });
}
