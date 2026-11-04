import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('native bridge creates keys and seals names', () {
    final path = Platform.environment['NNTDRIVE_FFI_PATH'];
    if (path == null || path.isEmpty) {
      // The regular unit test run does not build the Rust core; the client
      // build script sets NNTDRIVE_FFI_PATH and enables this test.
      return;
    }
    final bridge = NativeBridge.instance;
    final account = bridge.generateAccount('correct horse battery staple');
    final code = account['recovery_code'] as String;
    expect(code.startsWith('NNTR-'), true);

    final unlocked = bridge.unlock(
      jsonEncode(account['keyfile']),
      'correct horse battery staple',
    );
    final handle = unlocked['handle'] as int;
    const nodeId = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
    final sealed = bridge.sealName(handle, nodeId, 'Steuererklärung 2025.pdf');
    expect(bridge.openName(handle, nodeId, sealed), 'Steuererklärung 2025.pdf');

    // A different account cannot open the name.
    final other = bridge.generateAccount('another password entirely');
    final otherUnlocked = bridge.unlock(
      jsonEncode(other['keyfile']),
      'another password entirely',
    );
    expect(
      () => bridge.openName(otherUnlocked['handle'] as int, nodeId, sealed),
      throwsA(isA<NativeException>()),
    );
    bridge.lock(handle);
    bridge.lock(otherUnlocked['handle'] as int);
  });
}
