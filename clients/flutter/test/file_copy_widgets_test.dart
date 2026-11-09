import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/file_copy.dart';

void main() {
  testWidgets('row Copy disables folders and busy files with explanatory tooltip', (tester) async {
    var calls = 0;
    Future<void> show(bool isDir, bool busy) => tester.pumpWidget(MaterialApp(
      home: Scaffold(body: CopyFileButton(isDir: isDir, busy: busy, onCopy: () => calls++))));
    await show(true, false);
    expect(find.byTooltip('Folder Copy is not supported'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    await show(false, true);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    await show(false, false);
    await tester.tap(find.byTooltip('Copy file'));
    expect(calls, 1);
  });

  testWidgets('Copy is explicit, blocks duplicate admission and confirms success', (tester) async {
    final operation = Completer<Map<String, dynamic>>();
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: CopyFileDialog(runCopy: () {
      calls++;
      return operation.future;
    })));
    expect(calls, 0);
    expect(find.textContaining('Folder Copy is not supported'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(calls, 1);
    expect(find.byType(FilledButton), findsNothing);
    expect(tester.widget<TextButton>(find.byType(TextButton)).onPressed, isNull);
    expect(find.text('Copying encrypted metadata…'), findsOneWidget);
    operation.complete({'id': 'new-id', 'revision_id': 'new-revision'});
    await tester.pumpAndSettle();
    expect(find.textContaining('Copy confirmed.'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(calls, 1);
  });

  testWidgets('ambiguous failure is secret-free with refresh, never retry or success', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: CopyFileDialog(runCopy: () async {
      calls++;
      throw StateError('private credentials diagnostics');
    })));
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('lost response may already have committed'), findsOneWidget);
    expect(find.textContaining('private credentials'), findsNothing);
    expect(find.textContaining('Copy confirmed.'), findsNothing);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Refresh'), findsOneWidget);
    expect(calls, 1);
  });
}
