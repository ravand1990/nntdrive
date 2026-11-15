import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/folder_picker.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';

/// A namespace served from a map instead of HTTP; only folders matter here.
class _PickerApi extends ApiClient {
  _PickerApi(this.tree) : super(baseUrl: 'http://unused');
  final Map<String?, List<RemoteFile>> tree;
  int listings = 0;
  Object? failure;

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    listings++;
    if (failure != null) throw failure!;
    return tree[parentId] ?? const [];
  }
}

class _BlockingApi extends ApiClient {
  _BlockingApi() : super(baseUrl: 'http://unused');
  final listing = Completer<List<RemoteFile>>();
  int requests = 0;

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) {
    requests++;
    return listing.future;
  }
}

const _archiveId = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
const _reportsId = '7c1d5f4a-8b2d-4e6f-9a0b-1c2d3e4f5061';
const _fileId = '9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d';

Widget _host({
  required ApiClient api,
  required int handle,
  SessionOperations? operations,
  void Function(FolderChoice?) onResult = _ignore,
}) =>
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            final choice = await showDialog<FolderChoice>(
              context: context,
              builder: (_) => FolderPickerDialog(
                api: api,
                handle: handle,
                operations: operations,
              ),
            );
            onResult(choice);
          },
          child: const Text('Open'),
        ),
      ),
    );

void _ignore(FolderChoice? _) {}

void main() {
  late NativeBridge bridge;
  late int handle;

  setUpAll(() {
    bridge = NativeBridge.instance;
    final keys = bridge.generateAccount('folder picker password');
    handle = bridge
        .unlock(jsonEncode(keys['keyfile']), 'folder picker password')['handle'] as int;
  });

  tearDownAll(() => bridge.lock(handle));

  RemoteFile folder(String id, String? parentId, String name) => RemoteFile(
      id, parentId, bridge.sealName(handle, id, name), true, 0, false, 1, null);

  RemoteFile file(String id) => RemoteFile(
      id, null, bridge.sealName(handle, id, 'notes.txt'), false, 10, false, 1, null);

  testWidgets('the picker lists folders, opens them and returns the choice',
      (tester) async {
    final api = _PickerApi({
      null: [folder(_archiveId, null, 'Archive'), file(_fileId)],
      _archiveId: [folder(_reportsId, _archiveId, 'Reports')],
    });
    FolderChoice? result;
    await tester.pumpWidget(_host(
        api: api, handle: handle, onResult: (choice) => result = choice));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('My files'), findsOneWidget);
    expect(find.text('Archive'), findsOneWidget);
    expect(find.text('notes.txt'), findsNothing,
        reason: 'only folders can be chosen');

    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(find.text('Reports'), findsOneWidget);
    expect(find.text('My files'), findsNothing, reason: 'the path replaces it');

    await tester.tap(find.text('Use this folder'));
    await tester.pumpAndSettle();
    expect(result?.id, _archiveId);
    expect(result?.name, 'Archive');
  });

  testWidgets('a nested choice reports the whole path', (tester) async {
    final api = _PickerApi({
      null: [folder(_archiveId, null, 'Archive')],
      _archiveId: [folder(_reportsId, _archiveId, 'Reports')],
    });
    FolderChoice? result;
    await tester.pumpWidget(_host(
        api: api, handle: handle, onResult: (choice) => result = choice));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reports'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use this folder'));
    await tester.pumpAndSettle();

    expect(result?.id, _reportsId);
    expect(result?.name, 'Archive / Reports');
  });

  testWidgets('the account root is still a valid choice', (tester) async {
    final api = _PickerApi({
      null: [folder(_archiveId, null, 'Archive')],
    });
    FolderChoice? result;
    await tester.pumpWidget(_host(
        api: api, handle: handle, onResult: (choice) => result = choice));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use this folder'));
    await tester.pumpAndSettle();

    expect(result?.id, isNull);
    expect(result?.name, 'My files');
    expect(result?.isRoot, isTrue);
  });

  testWidgets('cancel returns no choice at all', (tester) async {
    final api = _PickerApi({null: [folder(_archiveId, null, 'Archive')]});
    FolderChoice? result;
    var answered = false;
    await tester.pumpWidget(_host(
        api: api,
        handle: handle,
        onResult: (choice) {
          result = choice;
          answered = true;
        }));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answered, isTrue);
    expect(result, isNull);
  });

  testWidgets('an unreadable listing explains itself and offers no choice',
      (tester) async {
    final api = _PickerApi({})..failure = StateError('private diagnostic');
    await tester.pumpWidget(_host(api: api, handle: handle));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Cannot read folders'), findsOneWidget);
    expect(find.textContaining('private diagnostic'), findsNothing);
    expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull,
        reason: 'a folder that could not be listed cannot be chosen');
  });

  testWidgets('a pending listing belongs to the session, not the dialog',
      (tester) async {
    final api = _BlockingApi();
    final operations = SessionOperations();
    await tester.pumpWidget(
        _host(api: api, handle: handle, operations: operations));
    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(api.requests, 1);

    var drained = false;
    final drain = operations.drain(handle).then((_) => drained = true);
    await tester.pump();
    expect(drained, isFalse, reason: 'the open listing is still running');

    api.listing.complete([folder(_archiveId, null, 'Archive')]);
    await tester.pumpAndSettle();
    await drain;
    expect(drained, isTrue);
    expect(find.text('Archive'), findsOneWidget);
  });
}
