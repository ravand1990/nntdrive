import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/rename_dialog.dart';

/// Android system back arrives as a `flutter/navigation` popRoute message.
Future<void> systemBack(WidgetTester tester) async {
  final message =
      const JSONMethodCodec().encodeMethodCall(const MethodCall('popRoute'));
  await tester.binding.defaultBinaryMessenger
      .handlePlatformMessage('flutter/navigation', message, (_) {});
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('back keeps typed rename text until the user discards it',
      (tester) async {
    String? result = 'unset';
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
    await tester.enterText(find.byType(TextFormField), 'draft name.txt');

    await systemBack(tester);
    expect(find.text('Discard your text?'), findsOneWidget);
    expect(find.byType(RenameDialog), findsOneWidget);
    expect(result, 'unset');

    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Discard your text?'), findsNothing);
    expect(find.text('draft name.txt'), findsOneWidget);

    await systemBack(tester);
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(RenameDialog), findsNothing);
    expect(result, isNull);
  });

  testWidgets('back closes an untouched rename dialog without a prompt',
      (tester) async {
    String? result = 'unset';
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

    await systemBack(tester);
    expect(find.text('Discard your text?'), findsNothing);
    expect(find.byType(RenameDialog), findsNothing);
    expect(result, isNull);
  });
}
