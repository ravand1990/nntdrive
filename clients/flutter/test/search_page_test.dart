import 'dart:async';

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

// pumpAndSettle only drains fake frames, not real isolate messages. Keep the
// production runner here and wait bounded real event turns for its UI result.
Future<void> waitForResult(WidgetTester tester,
    {bool Function()? until}) async {
  for (var i = 0;
      i < 500 &&
          (i < 5 ||
              find.byType(LinearProgressIndicator).evaluate().isNotEmpty ||
              !(until?.call() ??
                  find.text('Report.pdf').evaluate().isNotEmpty));
      i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

class RefreshFixture {
  String name = 'Report.pdf';
  bool offline = false;
  int listings = 0;
  int queries = 0;
  Completer<void>? listingGate;
  Completer<void>? queryGate;
  final operations = SessionOperations();
  late final index = AccountSearch(
    handle: 90,
    operations: operations,
    list: (_) async {
      listings++;
      await listingGate?.future;
      if (offline) throw StateError('private diagnostic');
      return [
        RemoteFile('f', null, name, false, 42, true, 1, null),
        RemoteFile('other', null, 'Other.txt', false, 42, false, 1, null),
      ];
    },
    decrypt: (f) => f.nameEnc,
    authorize: () {},
    queryWorker: (snapshot, filter, limit) async {
      queries++;
      final gate = queryGate;
      queryGate = null;
      await gate?.future;
      return runSearchQuery(snapshot, filter, limit);
    },
  );
}

void main() {
  testWidgets('typing coalesces bursts and dispatches within 50 ms',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(() => tester
        .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
    await waitForResult(tester);
    final before = f.queries;
    final field = find.widgetWithText(TextField, 'Search decrypted names');
    await tester.enterText(field, 'r');
    await tester.pump(const Duration(milliseconds: 20));
    await tester.enterText(field, 'report');
    await tester.pump(const Duration(milliseconds: 30));
    expect(f.queries, before); // The first pending timer was cancelled.
    await tester.pump(const Duration(milliseconds: 20));
    // Query serialization may await a future created in the real worker zone.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(f.queries, before + 1); // Leave time for worker scan/rendering.
    await waitForResult(tester);
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.text('Other.txt'), findsNothing);
    expect(f.queries, before + 1);
  });

  testWidgets('explicit search consumes the pending typing timer',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(() => tester
        .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
    await waitForResult(tester);
    final before = f.queries;
    await tester.enterText(
        find.widgetWithText(TextField, 'Search decrypted names'), 'report');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitForResult(tester);
    await tester.pump(const Duration(milliseconds: 250));
    await waitForResult(tester);
    expect(f.queries, before + 1);
    expect(f.index.recent.single.text, 'report');
    expect(find.text('Report.pdf'), findsOneWidget);
  });

  testWidgets('every page entry refreshes an already ready snapshot',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(f.index.rebuild);
    for (final name in ['New.pdf', 'Newest.pdf']) {
      f.name = name;
      await tester.runAsync(() => tester
          .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
      await waitForResult(tester,
          until: () => find.text(name).evaluate().isNotEmpty);
      expect(f.index.failed, isFalse);
      expect(f.index.building, isFalse);
      expect(find.text(name), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    }
    expect(f.listings, 3);
  });

  testWidgets(
      'external refresh reruns current query and filter; history is not a query',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(() => tester
        .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
    await waitForResult(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search decrypted names'), 'report');
    await tester.enterText(find.widgetWithText(TextField, 'Extension'), 'pdf');
    await tester.pump(const Duration(milliseconds: 200));
    await waitForResult(tester);
    final before = f.queries;
    f.index.remember(const SearchFilter(text: 'history'));
    f.index.remember(const SearchFilter(text: 'saved'), save: true);
    await tester.pump();
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(f.queries, before);
    f.name = 'Report-new.pdf';
    await tester.runAsync(f.index.rebuild);
    await waitForResult(tester,
        until: () => find.text(f.name).evaluate().isNotEmpty);
    expect(find.text('Report-new.pdf'), findsOneWidget);
    expect(find.text('Report.pdf'), findsNothing);
    expect(find.text('Other.txt'), findsNothing);
    expect(f.queries, before + 1);
    f.name = 'Report-new.txt';
    await tester.runAsync(f.index.rebuild);
    await waitForResult(tester,
        until: () => find.text('No indexed results').evaluate().isNotEmpty);
    expect(find.text('Report-new.txt'), findsNothing);
    expect(find.text('No indexed results'), findsOneWidget);
  });

  testWidgets(
      'offline entry and refresh retain results and stale warning until retry publishes',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(f.index.rebuild);
    f.offline = true;
    await tester.runAsync(() => tester
        .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
    await waitForResult(tester);
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.textContaining('may be stale'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search decrypted names'), 'report');
    await tester.pump(const Duration(milliseconds: 200));
    await waitForResult(tester);
    expect(find.textContaining('may be stale'), findsOneWidget);
    await tester
        .runAsync(() => tester.tap(find.byTooltip('Rebuild account index')));
    await waitForResult(tester,
        until: () => f.index.failed && !f.index.building);
    expect(find.text('Report.pdf'), findsOneWidget);
    f.offline = false;
    f.name = 'Report-recovered.pdf';
    await tester
        .runAsync(() => tester.tap(find.byTooltip('Rebuild account index')));
    await waitForResult(tester,
        until: () => find.text(f.name).evaluate().isNotEmpty);
    expect(find.text(f.name), findsOneWidget);
    expect(find.textContaining('may be stale'), findsNothing);
  });

  testWidgets('delayed old query cannot erase replacement snapshot results',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(() => tester
        .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
    await waitForResult(tester);
    final gate = Completer<void>();
    f.queryGate = gate;
    final before = f.queries;
    await tester.enterText(
        find.widgetWithText(TextField, 'Search decrypted names'), 'report');
    await tester.pump(const Duration(milliseconds: 200));
    await waitForResult(tester, until: () => f.queries > before);
    f.name = 'Report-replaced.pdf';
    await tester.runAsync(f.index.rebuild);
    gate.complete();
    await waitForResult(tester,
        until: () => find.text(f.name).evaluate().isNotEmpty);
    expect(find.text(f.name), findsOneWidget);
    expect(find.text('Report.pdf'), findsNothing);
  });

  testWidgets(
      'close during entry refresh clears names and prevents reappearance',
      (tester) async {
    final f = RefreshFixture();
    addTearDown(f.index.dispose);
    await tester.runAsync(f.index.rebuild);
    f.listingGate = Completer<void>();
    await tester.runAsync(() => tester
        .pumpWidget(MaterialApp(home: AccountSearchPage(index: f.index))));
    for (var i = 0; i < 50 && find.text('Report.pdf').evaluate().isEmpty; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(f.index.building, isTrue);
    f.index.close();
    await tester.pump();
    expect(find.text('Report.pdf'), findsNothing);
    f.listingGate!.complete();
    await tester.runAsync(() => f.operations.drain(90));
    await tester.pumpAndSettle();
    expect(find.text('Report.pdf'), findsNothing);
    expect(f.index.count, 0);
    expect(find.byKey(const Key('search-error')), findsNothing);
  });

  testWidgets(
      'account result shows path size honest status and returns selection; save and recent reuse',
      (tester) async {
    final index = (await tester.runAsync(fixture))!;
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
    await tester.runAsync(() async {
      await tester.tap(find.text('Open search'));
      await tester.pump();
    });
    await waitForResult(tester);
    await tester.enterText(
        find.widgetWithText(TextField, 'Search decrypted names'), 'Report');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await waitForResult(tester);
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.text('/Private folder · 42 bytes · Sync status unknown'),
        findsOneWidget);
    await tester.ensureVisible(find.text('Save filter'));
    await tester.tap(find.text('Save filter'));
    await tester.pumpAndSettle();
    await waitForResult(tester, until: () => index.saved.isNotEmpty);
    expect(index.saved.single.text, 'Report');
    expect(find.text('Saved: Report'), findsOneWidget);
    await tester.tap(find.text('Report.pdf'));
    await waitForResult(tester, until: () => selected != null);
    expect(selected?.file.id, 'f');
    expect(index.recent.single.text, 'Report');
    await tester.runAsync(() async {
      await tester.tap(find.text('Open search'));
      await tester.pump();
    });
    await waitForResult(tester);
    await tester.ensureVisible(find.text('Saved: Report'));
    await tester.tap(find.text('Saved: Report'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    await waitForResult(tester);
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
    final index = (await tester.runAsync(fixture))!;
    addTearDown(index.dispose);
    await tester.runAsync(() =>
        tester.pumpWidget(MaterialApp(home: AccountSearchPage(index: index))));
    await waitForResult(tester);
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
    await waitForResult(tester);
    expect(find.byKey(const Key('search-error')), findsNothing);
    expect(find.text('Report.pdf'), findsOneWidget);
    expect(find.text('Private folder'), findsOneWidget);
  });
}
