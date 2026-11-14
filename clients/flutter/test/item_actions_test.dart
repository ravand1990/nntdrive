import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/item_actions.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';

/// A browser listing with one folder and one file, plus recorded deletions.
class _ActionsApi extends ApiClient {
  _ActionsApi() : super(baseUrl: 'http://127.0.0.1:1', token: 'test-token');

  final List<RemoteFile> rootEntries = [];
  final List<String> deleted = [];

  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'actions@example.invalid', 'Tester', false, null, 0);

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async =>
      parentId == null ? List<RemoteFile>.of(rootEntries) : const <RemoteFile>[];

  @override
  Future<void> deleteFile(String id) async => deleted.add(id);
}

ItemActionSpec _spec(List<ItemActionSpec> specs, ItemActionKind kind) =>
    specs.firstWhere((spec) => spec.kind == kind);

void main() {
  group('item action specs', () {
    test('a folder offers opening and renaming but explains missing delete', () {
      final specs = itemActionSpecs(isDir: true, favorite: false, busy: false);
      expect(_spec(specs, ItemActionKind.open).label, 'Open folder');
      expect(_spec(specs, ItemActionKind.rename).enabled, isTrue);
      expect(_spec(specs, ItemActionKind.move).enabled, isTrue);
      expect(_spec(specs, ItemActionKind.copy).enabled, isTrue);
      // No content actions apply to a folder.
      expect(specs.map((s) => s.kind), isNot(contains(ItemActionKind.download)));
      // Deleting a folder would strand its children until Trash exists (#81).
      final delete = _spec(specs, ItemActionKind.delete);
      expect(delete.enabled, isFalse);
      expect(delete.destructive, isTrue);
      expect(delete.disabledReason, folderDeleteUnavailable);
      expect(delete.disabledReason, contains('#81'));
    });

    test('a file offers its content actions and a confirmed delete', () {
      final specs = itemActionSpecs(isDir: false, favorite: false, busy: false);
      expect(_spec(specs, ItemActionKind.download).enabled, isTrue);
      expect(_spec(specs, ItemActionKind.versions).enabled, isTrue);
      expect(_spec(specs, ItemActionKind.uploadVersion).enabled, isTrue);
      final favorite = _spec(specs, ItemActionKind.favorite);
      expect(favorite.label, 'Add favorite');
      final delete = _spec(specs, ItemActionKind.delete);
      expect(delete.enabled, isTrue);
      expect(delete.destructive, isTrue);
      expect(delete.subtitle, isNotNull);
    });

    test('a favourite file offers removing the favourite', () {
      final specs = itemActionSpecs(isDir: false, favorite: true, busy: false);
      final favorite = _spec(specs, ItemActionKind.favorite);
      expect(favorite.label, 'Remove favorite');
      expect(favorite.icon, Icons.star);
    });

    test('a running operation disables every mutating action with a reason', () {
      for (final isDir in [true, false]) {
        final specs = itemActionSpecs(isDir: isDir, favorite: false, busy: true);
        for (final kind in [
          ItemActionKind.rename,
          ItemActionKind.move,
          ItemActionKind.copy,
          if (!isDir) ItemActionKind.uploadVersion,
          if (!isDir) ItemActionKind.favorite,
          if (!isDir) ItemActionKind.delete,
        ]) {
          final spec = _spec(specs, kind);
          expect(spec.enabled, isFalse, reason: '$kind must wait for the run');
          expect(spec.disabledReason, busyActionUnavailable);
        }
        // A folder's delete explains the missing Trash feature, not the run.
        if (isDir) {
          final folderDelete = _spec(specs, ItemActionKind.delete);
          expect(folderDelete.enabled, isFalse);
          expect(folderDelete.disabledReason, folderDeleteUnavailable);
        }
        // Read-only actions stay available; a folder offers opening instead.
        expect(specs.where((s) => s.kind == ItemActionKind.open).length,
            isDir ? 1 : 0);
        if (!isDir) {
          expect(_spec(specs, ItemActionKind.download).enabled, isTrue);
          expect(_spec(specs, ItemActionKind.versions).enabled, isTrue);
        }
      }
    });
  });

  group('file browser item menu', () {
    late NativeBridge bridge;
    late int handle;
    late _ActionsApi api;
    late SessionOperations operations;

    Future<void> pumpBrowser(WidgetTester tester) async {
      bridge = NativeBridge.instance;
      final keys = await tester.runAsync(
          () => bridge.generateAccountAsync('item actions password'));
      handle = (await tester.runAsync(() async => bridge.unlock(
          jsonEncode(keys!['keyfile']),
          'item actions password')['handle'] as int))!;
      const folderId = '2b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const fileId = '5c1d3e5a-7f2b-4c8d-9e0f-1a2b3c4d5e6f';
      api = _ActionsApi()
        ..rootEntries.addAll([
          RemoteFile(folderId, null, bridge.sealName(handle, folderId, 'Docs'), true,
              0, false, 3, null),
          RemoteFile(fileId, null, bridge.sealName(handle, fileId, 'report.pdf'), false,
              2048, false, 4, null),
        ]);
      operations = SessionOperations();
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
            email: 'actions@example.invalid',
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
    }

    testWidgets('each row shows one labelled overflow control instead of icon sprawl',
        (tester) async {
      await pumpBrowser(tester);

      expect(find.byTooltip('More actions for report.pdf'), findsOneWidget);
      expect(find.byTooltip('More actions for Docs'), findsOneWidget);
      // The individual action icons are no longer competing for row space.
      expect(find.byTooltip('Rename file'), findsNothing);
      expect(find.byTooltip('Move file'), findsNothing);
      expect(find.byTooltip('Copy file'), findsNothing);

      final size = tester.getSize(find.byTooltip('More actions for report.pdf'));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    });

    testWidgets('a file menu reaches rename, move, copy and delete', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byTooltip('More actions for report.pdf'));
      await tester.pumpAndSettle();

      expect(find.text('Rename file'), findsOneWidget);
      expect(find.text('Move file'), findsOneWidget);
      expect(find.text('Copy file'), findsOneWidget);
      expect(find.text('Delete file'), findsOneWidget);
      expect(find.text('Download and verify'), findsOneWidget);
      expect(find.text('Version history'), findsOneWidget);
    });

    testWidgets('deleting a file asks before removing it', (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byTooltip('More actions for report.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete file'));
      await tester.pumpAndSettle();

      expect(find.text('Delete file?'), findsOneWidget);
      expect(api.deleted, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty, reason: 'cancel must not delete anything');

      await tester.tap(find.byTooltip('More actions for report.pdf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();

      expect(api.deleted, ['5c1d3e5a-7f2b-4c8d-9e0f-1a2b3c4d5e6f']);
    });

    testWidgets('a folder menu opens it and explains why delete is unavailable',
        (tester) async {
      await pumpBrowser(tester);

      await tester.tap(find.byTooltip('More actions for Docs'));
      await tester.pumpAndSettle();

      expect(find.text('Open folder'), findsOneWidget);
      final deleteRow = find.widgetWithText(ListTile, 'Delete folder');
      expect(deleteRow, findsOneWidget);
      expect(tester.widget<ListTile>(deleteRow).enabled, isFalse);
      expect(find.text(folderDeleteUnavailable), findsOneWidget);

      await tester.tap(find.text('Open folder'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Up one folder'), findsOneWidget);
    });
  });
}
