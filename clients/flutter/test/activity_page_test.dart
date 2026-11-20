import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/activity_log.dart';
import 'package:nntdrive/activity_page.dart';

class MemoryActivityStore implements ActivityStore {
  ActivitySnapshot snapshot = const ActivitySnapshot();

  @override
  Future<ActivitySnapshot> load() async => snapshot;

  @override
  Future<void> save(ActivitySnapshot value) async {
    snapshot = value;
  }
}

void main() {
  final clock = DateTime(2026, 11, 20, 12);

  Future<ActivityLog> pumpPage(
    WidgetTester tester, {
    void Function(ActivityLog log)? seed,
  }) async {
    final log = ActivityLog(
      store: MemoryActivityStore(),
      accountId: 'account-1',
      clock: () => clock,
    );
    await log.load();
    log.record(
      kind: ActivityKind.uploaded,
      folder: 'Documents',
      subject: 'budget.pdf',
      itemId: 'node-1',
      size: 2048,
    );
    log.record(
      kind: ActivityKind.failed,
      folder: 'Documents',
      subject: 'sync',
      reason: 'Server unreachable',
    );
    log.record(
      kind: ActivityKind.conflict,
      folder: 'Photos',
      subject: '1 item',
      reason: 'Choose a copy',
    );
    seed?.call(log);
    await tester.pumpWidget(MaterialApp(home: ActivityPage(log: log)));
    await tester.pumpAndSettle();
    return log;
  }

  testWidgets('shows the empty state before anything happens', (tester) async {
    final log = ActivityLog(
      store: MemoryActivityStore(),
      accountId: 'account-1',
      clock: () => clock,
    );
    await tester.pumpWidget(MaterialApp(home: ActivityPage(log: log)));
    await tester.pumpAndSettle();
    expect(find.textContaining('No activity yet'), findsOneWidget);
  });

  testWidgets('lists rows and filters them by kind', (tester) async {
    await pumpPage(tester);
    expect(find.text('Uploaded budget.pdf'), findsOneWidget);
    // The failure is listed as a row and as a notification.
    expect(find.text('Failed sync'), findsNWidgets(2));
    expect(find.text('Conflict 1 item'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(FilterChip, 'Uploaded'));
    await tester.pumpAndSettle();
    expect(find.text('Uploaded budget.pdf'), findsOneWidget);
    // Filters apply to the feed; the notification section stays visible.
    expect(find.byType(ActivityRow), findsOneWidget);
    expect(find.text('Failed sync'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'All'));
    await tester.pumpAndSettle();
    expect(find.text('Failed sync'), findsNWidgets(2));
  });

  testWidgets('dismissing a notification keeps the underlying row', (
    tester,
  ) async {
    final log = await pumpPage(tester);
    expect(log.notificationCount, 2);
    expect(find.text('Needs attention'), findsOneWidget);

    // One row can be dismissed on its own.
    await tester.tap(find.text('Dismiss').first);
    await tester.pumpAndSettle();
    expect(log.notificationCount, 1);

    await tester.tap(find.text('Dismiss all'));
    await tester.pumpAndSettle();
    expect(log.notificationCount, 0);
    expect(find.text('Needs attention'), findsNothing);
    // The failure is still readable in the feed after its notification is gone.
    expect(find.text('Failed sync'), findsOneWidget);
    expect(find.text('Server unreachable'), findsOneWidget);
  });

  testWidgets('export defaults to redacted and can include local names', (
    tester,
  ) async {
    await pumpPage(tester);
    await tester.tap(find.byTooltip('Export activity report'));
    await tester.pumpAndSettle();

    String report() => tester
        .widget<SelectableText>(find.byKey(const Key('activity-export-text')))
        .data!;
    // Redacted by default: opaque ids stand in for local names.
    expect(report(), contains('node-1'));
    expect(report(), isNot(contains('budget.pdf')));
    expect(report(), isNot(contains('Documents')));

    await tester.tap(find.widgetWithText(ChoiceChip, 'Include local names'));
    await tester.pumpAndSettle();
    expect(report(), contains('budget.pdf'));
    expect(report(), contains('Documents'));
  });

  testWidgets('clear history asks first and empties the feed', (tester) async {
    final log = await pumpPage(tester);
    await tester.tap(find.byTooltip('Clear activity history'));
    await tester.pumpAndSettle();
    expect(find.text('Clear activity?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(log.entries, isEmpty);
    expect(find.textContaining('No activity yet'), findsOneWidget);
  });

  testWidgets('each row reads as one sentence for screen readers', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(
      find.bySemanticsLabel('Uploaded, budget.pdf, Documents, 20 Nov 12:00'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Failed, sync, Documents, 20 Nov 12:00, Server unreachable',
      ),
      findsOneWidget,
    );
  });
}
