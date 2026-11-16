import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/item_actions.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/update_checks.dart';

/// One folder and one file at the account root.
class _RowApi extends ApiClient {
  _RowApi(this.files) : super(baseUrl: 'http://127.0.0.1:1', token: 'test-token');

  final List<RemoteFile> files;

  @override
  Future<AccountInfo> me() async =>
      AccountInfo('account', 'focus@example.invalid', 'Tester', false, null, 0);

  @override
  Future<List<RemoteFile>> listFiles({String? parentId}) async =>
      parentId == null ? files : const [];
}

/// The name a screen reader gets for one control: the nearest tooltip, semantic
/// label or visible text it carries, looked for in its own subtree first and
/// then above it.
String _announcedName(BuildContext context) {
  final below = <String>[];
  void collect(Element element, int depth) {
    if (below.isNotEmpty || depth > 8) return;
    final widget = element.widget;
    if (widget is Tooltip && widget.message != null) below.add(widget.message!);
    if (widget is Semantics && widget.properties.label != null) {
      below.add(widget.properties.label!);
    }
    if (widget is Text) {
      final data = widget.data ?? widget.textSpan?.toPlainText();
      if (data != null && data.isNotEmpty) below.add(data);
    }
    if (below.isNotEmpty) return;
    element.visitChildren((child) => collect(child, depth + 1));
  }

  collect(context as Element, 0);
  if (below.isNotEmpty) return below.first;

  final above = <String>[];
  context.visitAncestorElements((element) {
    final widget = element.widget;
    if (widget is Tooltip && widget.message != null) above.add(widget.message!);
    if (widget is Semantics && widget.properties.label != null) {
      above.add(widget.properties.label!);
    }
    if (widget is Text) {
      final data = widget.data ?? widget.textSpan?.toPlainText();
      if (data != null && data.isNotEmpty) above.add(data);
    }
    return above.isEmpty;
  });
  return above.isEmpty ? '' : above.first;
}

/// Opens the browser at a phone-plus width, the size where every row control is
/// on screen at once.
Future<void> _pumpBrowser(WidgetTester tester) async {
  final bridge = NativeBridge.instance;
  final keys = await tester.runAsync(
      () => bridge.generateAccountAsync('focus order password'));
  final handle = (await tester.runAsync(() async =>
      bridge.unlock(jsonEncode(keys!['keyfile']), 'focus order password')[
          'handle'] as int))!;
  const folderId = '2f6a4b58-0f61-4a5e-9a10-3a4d0e7b1101';
  const fileId = '2f6a4b58-0f61-4a5e-9a10-3a4d0e7b1102';
  final api = _RowApi([
    RemoteFile(folderId, null, bridge.sealName(handle, folderId, 'Archive'),
        true, 0, false, 1, null),
    RemoteFile(fileId, null, bridge.sealName(handle, fileId, 'Notes.txt'), false,
        12, false, 1, null),
  ]);
  final operations = SessionOperations();
  await tester.binding.setSurfaceSize(const Size(800, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(MaterialApp(
    home: FilesPage(
      session: Session(
        server: 'http://127.0.0.1:1',
        token: 'test-token',
        handle: handle,
        accountId: 'account',
        email: 'focus@example.invalid',
        operations: operations,
      ),
      sync: SyncController(
          server: 'http://127.0.0.1:1',
          token: 'test-token',
          handle: handle,
          api: api),
      operations: operations,
      updates: UpdateChecks(check: () async => null, prompt: (_) async => true),
      themeMode: ThemeMode.light,
      onTheme: (_) {},
      onSignOut: () {},
      api: api,
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('file browser Tab order follows the screen and every stop is named',
      (tester) async {
    await _pumpBrowser(tester);

    final names = <String>[];
    final centers = <Offset>[];
    // Enough stops for every app-bar action, the filter field, both rows, their
    // action buttons, the trash entry and the primary "New" button.
    for (var i = 0; i < 14; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final context = FocusManager.instance.primaryFocus?.context;
      if (context == null) break;
      final box = context.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final center = box.localToGlobal(box.size.center(Offset.zero));
      if (centers.isNotEmpty && centers.last == center) continue;
      // Tab wraps back to the first control once the walk is complete.
      if (centers.contains(center)) break;
      centers.add(center);
      names.add(_announcedName(context));
    }

    // The app-bar actions, the filter field, both rows and their action buttons
    // and the primary "New" button are all reachable by keyboard.
    expect(names.length, greaterThanOrEqualTo(9),
        reason: 'every visible control must be reachable with Tab: $names');
    for (var i = 1; i < centers.length; i++) {
      final previous = centers[i - 1];
      final current = centers[i];
      final readsOn = current.dy > previous.dy + 1 ||
          (current.dy - previous.dy).abs() <= 1 &&
              current.dx > previous.dx + 1;
      expect(readsOn, isTrue,
          reason: 'focus order jumps backwards: ${names.join(' -> ')}');
    }
    expect(names.first, contains('Search all files'));
    expect(names.last, contains('New'));
    // The row actions are reached between the rows and the "New" button, so the
    // two rows' overflow controls are in the walk.
    expect(names.where((n) => n.startsWith('More actions for')).length, 2,
        reason: 'both rows must offer their actions to the keyboard: $names');
  });

  testWidgets('every icon-only control is named and keeps a 48dp target',
      (tester) async {
    await _pumpBrowser(tester);

    final buttons = find.byType(IconButton);
    expect(buttons, findsWidgets);
    for (final element in buttons.evaluate()) {
      final button = element.widget as IconButton;
      expect(button.tooltip, isNotNull,
          reason: 'icon-only control without a TalkBack label');
      expect(button.tooltip!.trim(), isNotEmpty,
          reason: 'icon-only control without a TalkBack label');
      final size = tester.getSize(find.byWidget(button));
      expect(size.width, greaterThanOrEqualTo(48),
          reason: '${button.tooltip} is narrower than a 48dp target');
      expect(size.height, greaterThanOrEqualTo(48),
          reason: '${button.tooltip} is shorter than a 48dp target');
    }

    // The item sheet offers every action as a full-width row, so each stays a
    // comfortable target with a visible text label.
    await tester.tap(find.byTooltip('More actions for Notes.txt'));
    await tester.pumpAndSettle();
    final sheetRows = find.descendant(
        of: find.byType(ItemActionsSheet), matching: find.byType(ListTile));
    expect(sheetRows, findsWidgets);
    for (final element in sheetRows.evaluate()) {
      final row = element.widget as ListTile;
      final title = row.title;
      expect(title, isA<Text>(),
          reason: 'an action row needs a visible text label');
      expect(tester.getSize(find.byWidget(row)).height,
          greaterThanOrEqualTo(48),
          reason: '${(title as Text).data} is shorter than a 48dp target');
    }
  });
}
