import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nntdrive/main.dart';

void main() {
  testWidgets('shows login and registration options', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(NntDriveApp(prefs: prefs));
    await tester.pumpAndSettle();

    expect(find.text('NNTDrive'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);
  });

  testWidgets('locked vault explains paused sync without unlocking automatically',
      (WidgetTester tester) async {
    var unlocks = 0;
    await tester.pumpWidget(MaterialApp(
      home: UnlockPage(
        server: 'http://127.0.0.1:1',
        email: 'test@example.invalid',
        keyfileJson: '{}',
        accountId: 'test-account',
        token: 'test-token',
        onUnlocked: (_) async { unlocks++; },
        onSignOut: () {},
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Sync paused: vault locked. Unlock to allow synchronization.'),
        findsOneWidget);
    expect(unlocks, 0);
    await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
    await tester.pumpAndSettle();
    expect(unlocks, 1);
  });

  test('formats byte sizes', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1.0 KiB');
    expect(formatBytes(1536), '1.5 KiB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MiB');
  });
}
