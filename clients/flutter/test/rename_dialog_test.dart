import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/rename_dialog.dart';

void main() {
  testWidgets('rename dialog validates, preserves input and supports cancel',
      (tester) async {
    String? result;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => TextButton(
                onPressed: () async {
                  result = await showDialog<String>(
                      context: context,
                      builder: (_) => const RenameDialog(
                          initialName: 'old.txt', isDir: false));
                },
                child: const Text('Open')))));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('old.txt'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), '../bad');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.byType(RenameDialog), findsOneWidget);
    await tester.enterText(find.byType(TextFormField), 'new.txt');
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(result, 'new.txt');
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
