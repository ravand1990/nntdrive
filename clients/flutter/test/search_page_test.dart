import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/search_page.dart';
import 'package:nntdrive/session_operations.dart';

Future<AccountSearch> fixture() async {
  final index = AccountSearch(
      handle: 1,
      operations: SessionOperations(),
      list: (p) async => p == null
          ? [RemoteFile('d', null, 'opaque-folder', true, 0, false, 1, null)]
          : [RemoteFile('f', 'd', 'opaque-file', false, 42, true, 1, null)],
      decrypt: (f) => f.isDir ? 'Private folder' : 'Report.pdf',
      authorize: () {});
  await index.rebuild();
  return index;
}

void main() {
  testWidgets(
      'account result shows path size honest status and returns selection; save and recent reuse',
      (tester) async {
    final index = await fixture();
    addTearDown(index.dispose);
    SearchEntry? selected;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  selected = await Navigator.of(context).push<SearchEntry>(
                      MaterialPageRoute(
                          builder: (_) => AccountSearchPage(index: index)));
                },
                child: const Text('Open search')))));
    await tester.tap(find.text('Open search'));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.widgetWithText(TextField, 'Search decrypted names'), 'Report');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.text('/Private folder · 42 bytes · Sync status unknown'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Save filter'));
    await tester.tap(find.text('Save filter'));
    await tester.pumpAndSettle();
    expect(index.saved.single.text, 'Report');
    expect(find.text('Saved: Report'), findsOneWidget);
    await tester.tap(find.text('Report.pdf'));
    await tester.pumpAndSettle();
    expect(selected?.file.id, 'f');
    expect(index.recent.single.text, 'Report');
    await tester.tap(find.text('Open search'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Saved: Report'));
    await tester.tap(find.text('Saved: Report'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Report'), findsOneWidget);
    index.close();
    await tester.pumpAndSettle();
    expect(find.text('Report.pdf'), findsNothing);
    expect(find.text('Saved: Report'), findsNothing);
    expect(find.widgetWithText(TextField, 'Report'), findsNothing);
  });

  testWidgets(
      'small viewport stays scrollable and invalid dates never show raw diagnostics',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final index = await fixture();
    addTearDown(index.dispose);
    await tester.pumpWidget(MaterialApp(home: AccountSearchPage(index: index)));
    await tester.pumpAndSettle();
    final date = find.widgetWithText(TextField, 'Modified since (UTC)');
    await tester.ensureVisible(date);
    await tester.enterText(date, '2026-02-30');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('search-error')));
    expect(
        find.text(
            'Use nonnegative byte sizes and valid YYYY-MM-DD date ranges.'),
        findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Clear filters'));
    await tester.tap(find.text('Clear filters'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-error')), findsNothing);
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.text('Private folder'), findsOneWidget);
  });
}
