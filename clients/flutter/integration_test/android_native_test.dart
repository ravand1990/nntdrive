import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nntdrive/native.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android packaged FFI crypto and app-private storage',
      (tester) async {
    expect(Platform.isAndroid, isTrue);
    // No path override: exercise Android's packaged .so loader.
    expect(Platform.environment['NNTDRIVE_FFI_PATH'], isNull);
    final bridge = NativeBridge.instance;
    final account = bridge.generateAccount('emulator smoke password');
    expect(account['recovery_code'], startsWith('NNTR-'));
    final unlocked = bridge.unlock(
      jsonEncode(account['keyfile']),
      'emulator smoke password',
    );
    final handle = unlocked['handle'] as int;
    try {
      const nodeId = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const name = 'Android encrypted filename.pdf';
      final sealed = bridge.sealName(handle, nodeId, name);
      expect(bridge.openName(handle, nodeId, sealed), name);
      expect(
        () => bridge.unlock(jsonEncode(account['keyfile']), 'wrong password'),
        throwsA(isA<NativeException>()),
      );
      // Real platform-channel path lookup and filesystem, not mocked preferences.
      final support = await getApplicationSupportDirectory();
      final scratch =
          await Directory(support.path).createTemp('ci-native-smoke-');
      try {
        final file = File('${scratch.path}/sealed-name');
        await file.writeAsString(sealed, flush: true);
        expect(
            bridge.openName(handle, nodeId, await file.readAsString()), name);
      } finally {
        await scratch.delete(recursive: true);
      }
    } finally {
      bridge.lock(handle);
    }
  });
}
