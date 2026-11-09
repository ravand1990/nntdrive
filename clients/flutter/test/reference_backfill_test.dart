import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/reference_backfill.dart';

void main() {
  testWidgets('explicit batches block duplicates and expose safe retry/results', (tester) async {
    var calls = 0;
    final first = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(home: ReferenceBackfillDialog(runBatch: () async {
      calls++;
      if (calls == 1) return first.future;
      if (calls == 2) throw Exception('private token must not appear');
      return {'completed': 0, 'more': false, 'failed': false};
    })));
    expect(calls, 0);
    await tester.tap(find.text('Start batch'));
    await tester.pump();
    expect(calls, 1);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    first.complete({'completed': 200, 'more': true, 'failed': false});
    await tester.pumpAndSettle();
    expect(find.textContaining('200 revision(s)'), findsOneWidget);
    await tester.tap(find.text('Continue / retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Backfill failed'), findsOneWidget);
    expect(find.textContaining('private token'), findsNothing);
    await tester.tap(find.text('Continue / retry'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.textContaining('No more incomplete'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });
}
