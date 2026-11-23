import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/search_navigation.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/storage_usage.dart';
import 'package:nntdrive/storage_usage_page.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';

const folderId = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
const fileId = '1b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';

class NavigationApi extends ApiClient {
  NavigationApi(this.handle, this.rootFile)
    : super(baseUrl: 'http://127.0.0.1:1', token: 'fixture');
  final int handle;
  final bool rootFile;
  String folderName = 'Old folder';
  bool missing = false;
  bool corrupt = false;
  bool offline = false;
  Completer<void>? gate;
  final parents = <String?>[];
  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'fixture@example.invalid', 'Test', false, null, 0);
  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    parents.add(parentId);
    await gate?.future;
    if (offline) throw StateError('private transport diagnostic');
    final bridge = NativeBridge.instance;
    RemoteFile file() => RemoteFile(
      fileId,
      rootFile ? null : folderId,
      corrupt ? 'bad envelope' : bridge.sealName(handle, fileId, 'Private.txt'),
      false,
      oldestLargeMinimumBytes,
      false,
      1,
      null,
      updatedAt: DateTime.utc(2020),
    );
    if (parentId == null) {
      return rootFile
          ? [if (!missing) file()]
          : [
              RemoteFile(
                folderId,
                null,
                bridge.sealName(handle, folderId, folderName),
                true,
                0,
                false,
                1,
                null,
              ),
            ];
    }
    return [if (!missing) file()];
  }
}

class NavigationSession extends Session {
  NavigationSession(this.index, int handle, SessionOperations operations)
    : super(
        server: 'http://127.0.0.1:1',
        token: 'fixture',
        handle: handle,
        accountId: 'account',
        email: 'fixture@example.invalid',
        operations: operations,
      );
  final AccountSearch index;
  @override
  AccountSearch get search => index;
}

Future<void> turns(WidgetTester tester) async {
  for (var i = 0; i < 150; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (i > 30 &&
        find.byType(LinearProgressIndicator).evaluate().isEmpty &&
        find.byType(CircularProgressIndicator).evaluate().isEmpty) {
      return;
    }
  }
  fail('navigation did not finish');
}

void main() {
  for (final (rootFile, oldest, failure) in [
    (false, false, ''),
    (false, true, ''),
    (true, false, ''),
    (true, true, ''),
    (false, false, 'missing'),
    (false, false, 'corrupt'),
    (false, false, 'offline'),
  ]) {
    testWidgets(
      'dashboard ${oldest ? 'oldest' : 'largest'} opens ${rootFile ? 'root' : 'fresh named parent'} in app $failure',
      (tester) async {
        final bridge = NativeBridge.instance;
        final keys = await tester.runAsync(
          () => bridge.generateAccountAsync('navigation fixture'),
        );
        final handle =
            bridge.unlock(
                  jsonEncode(keys!['keyfile']),
                  'navigation fixture',
                )['handle']
                as int;
        final operations = SessionOperations();
        final api = NavigationApi(handle, rootFile);
        final index = AccountSearch(
          handle: handle,
          operations: operations,
          list: (parent) => api.listFiles(parentId: parent),
          decrypt: (file) => bridge.openName(handle, file.id, file.nameEnc),
          authorize: () {
            bridge.sealName(handle, fileId, '');
          },
        );
        final session = NavigationSession(index, handle, operations);
        final sync = SyncController(
          server: api.baseUrl,
          token: 'fixture',
          handle: handle,
          api: api,
        );
        await tester.runAsync(
          () => tester.pumpWidget(
            MaterialApp(
              home: FilesPage(
                session: session,
                sync: sync,
                operations: operations,
                api: api,
                updates: UpdateChecks(
                  check: () async => null,
                  prompt: (_) async => true,
                ),
                themeMode: ThemeMode.light,
                onTheme: (_) {},
                onSignOut: () {},
              ),
            ),
          ),
        );
        await turns(tester);
        await tester.tap(find.byTooltip('Account'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Storage usage'));
        await tester.runAsync(() => tester.tap(find.text('Storage usage')));
        await turns(tester);
        await tester.pumpAndSettle();
        final subtitle = oldest
            ? '10485760 bytes · 2020-01-01T00:00:00.000Z (UTC)'
            : '10485760 bytes';
        await tester.scrollUntilVisible(
          find.text(subtitle),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        final tile = find.ancestor(
          of: find.text(subtitle),
          matching: find.byType(ListTile),
        );
        final action = find.descendant(
          of: tile,
          matching: find.text('Open containing folder'),
        );
        expect(action, findsOneWidget);
        await tester.ensureVisible(action);
        await tester.pumpAndSettle();
        api.folderName = 'Fresh folder';
        api.missing = failure == 'missing';
        api.corrupt = failure == 'corrupt';
        api.offline = failure == 'offline';
        api.parents.clear();
        await tester.runAsync(() => tester.tap(action));
        await turns(tester);
        await tester.pumpAndSettle();
        expect(find.byType(StorageUsagePage), findsNothing);
        if (failure.isNotEmpty) {
          expect(
            find.text('Folder unavailable. Refresh the source page and retry.'),
            findsOneWidget,
          );
          expect(
            find.textContaining('private transport diagnostic'),
            findsNothing,
          );
          expect(find.text('Fresh folder'), findsNothing);
          expect(find.text('My files'), findsOneWidget);
        } else {
          expect(
            find.text(rootFile ? 'My files' : 'Fresh folder'),
            findsOneWidget,
          );
          expect(find.text('Private.txt'), findsOneWidget);
          expect(find.text('Old folder'), findsNothing);
          expect(
            find.text('Download'),
            findsNothing,
            reason: 'must not open file actions',
          );
          final expected = rootFile ? [null, null] : [null, folderId, folderId];
          expect(api.parents.take(expected.length), expected);
        }
        expect(api.parents, everyElement(anyOf(isNull, folderId)));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        index.close();
        await operations.drain(handle);
        bridge.lock(handle);
        sync.dispose();
      },
    );
  }

  test(
    'fresh traversal rejects moved/deleted/type/ciphertext errors and drains close',
    () async {
      final operations = SessionOperations();
      final folder = RemoteFile('folder', null, 'enc', true, 0, false, 1, null);
      final file = RemoteFile(
        'file',
        'folder',
        'enc',
        false,
        1,
        false,
        1,
        null,
      );
      final index = AccountSearch(
        handle: 1,
        operations: operations,
        list: (parent) async => parent == null ? [folder] : [file],
        decrypt: (file) => file.id,
        authorize: () {},
      );
      await index.rebuild();
      final directory = await index.readSnapshot(
        (snapshot) async => snapshot['folder']!,
      );
      for (final containingOnly in [false, true]) {
        final location = await resolveSearchLocation(
          index: index,
          entry: directory,
          containingOnly: containingOnly,
          list: (_) async => [folder],
          decrypt: (_) async => {'folder': 'Fresh directory'},
        );
        expect(
          location.map((entry) => entry.name),
          containingOnly ? isEmpty : ['Fresh directory'],
        );
      }
      var entry = await index.readSnapshot(
        (snapshot) async => snapshot['file']!,
      );
      Future<List<SearchEntry>> resolve(
        Future<List<RemoteFile>> Function(String?) list, {
        Future<Map<String, String>> Function(List<RemoteFile>)? decrypt,
      }) => resolveSearchLocation(
        index: index,
        entry: entry,
        containingOnly: true,
        list: list,
        decrypt:
            decrypt ??
            (files) async => {for (final file in files) file.id: file.id},
      );
      for (final bad in [
        <RemoteFile>[],
        [file, file],
        [RemoteFile('file', 'moved', 'enc', false, 1, false, 1, null)],
        [RemoteFile('file', 'folder', 'enc', true, 0, false, 1, null)],
      ]) {
        await expectLater(
          resolve((parent) async => parent == null ? [folder] : bad),
          throwsA(isA<SearchUnavailable>()),
        );
      }
      await expectLater(
        resolve(
          (parent) async => [folder],
          decrypt: (_) async => throw StateError('private ciphertext error'),
        ),
        throwsA(isA<SearchUnavailable>()),
      );
      final replacedGate = Completer<List<RemoteFile>>();
      final replaced = resolve(
        (parent) async => parent == null ? await replacedGate.future : [file],
      );
      final rejected = expectLater(replaced, throwsA(isA<SearchUnavailable>()));
      await index.rebuild();
      replacedGate.complete([folder]);
      await rejected;
      var staleLists = 0;
      await expectLater(
        resolve((_) async {
          staleLists++;
          return [];
        }),
        throwsA(isA<SearchUnavailable>()),
      );
      expect(staleLists, 0);
      entry = await index.readSnapshot((snapshot) async => snapshot['file']!);
      final gate = Completer<List<RemoteFile>>();
      var decrypted = false;
      final pending = resolve(
        (_) => gate.future,
        decrypt: (_) async {
          decrypted = true;
          return {};
        },
      );
      final failure = expectLater(pending, throwsA(isA<SearchUnavailable>()));
      index.close();
      var drained = false;
      final drain = operations.drain(1).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      gate.complete([folder]);
      await failure;
      await drain;
      expect(decrypted, isFalse);
      index.dispose();
    },
  );
}
