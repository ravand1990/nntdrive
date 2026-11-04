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

  test('formats byte sizes', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(1024), '1.0 KiB');
    expect(formatBytes(1536), '1.5 KiB');
    expect(formatBytes(5 * 1024 * 1024), '5.0 MiB');
  });
}
