import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Windows app shell and packaged native FFI smoke',
      (tester) async {
    expect(Platform.isWindows, isTrue);
    // The workflow copies the release ZIP's DLL beside the test runner.
    expect(Platform.environment['NNTDRIVE_FFI_PATH'], isNull);

    SharedPreferences.setMockInitialValues({
      'updateAutoCheck': false,
      'server': '',
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(NntDriveApp(prefs: prefs));
    await tester.pumpAndSettle();

    expect(find.text('NNTDrive'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Create account'), findsOneWidget);
    expect(find.text('Server URL'), findsOneWidget);

    final bridge = NativeBridge.instance;
    const password = 'Windows smoke test password';
    final account = bridge.generateAccount(password);
    expect(account['recovery_code'], startsWith('NNTR-'));
    final unlocked = bridge.unlock(jsonEncode(account['keyfile']), password);
    final handle = unlocked['handle'] as int;
    try {
      const nodeId = '8f397f32-0e27-4f5e-8ea5-24be14e46df0';
      const name = 'Windows encrypted filename.pdf';
      final sealed = bridge.sealName(handle, nodeId, name);
      expect(bridge.openName(handle, nodeId, sealed), name);
      expect(
        () => bridge.unlock(jsonEncode(account['keyfile']), 'wrong password'),
        throwsA(isA<NativeException>()),
      );

      final support = await getApplicationSupportDirectory();
      final scratch =
          await Directory(support.path).createTemp('ci-native-smoke-');
      try {
        final file = File('${scratch.path}\\sealed-name');
        await file.writeAsString(sealed, flush: true);
        expect(
          bridge.openName(handle, nodeId, await file.readAsString()),
          name,
        );
      } finally {
        await scratch.delete(recursive: true);
      }
    } finally {
      bridge.lock(handle);
    }
  });
}
