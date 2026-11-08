import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('sync callback lifetime terminates even on native errors', () async {
    final events = <Map<String, dynamic>>[];
    await expectLater(
        NativeBridge.instance.syncRequestAsync(0, {}, onProgress: events.add),
        throwsA(isA<NativeException>()));
    expect(events, isEmpty);
    // A second request proves the first listener was closed without poisoning ABI state.
    await expectLater(NativeBridge.instance.syncRequestAsync(0, {}),
        throwsA(isA<NativeException>()));
  });
  test('native bridge creates keys and seals names', () async {
    final path = Platform.environment['NNTDRIVE_FFI_PATH'];
    expect(path, isNotNull,
        reason: 'Build the Rust core and set NNTDRIVE_FFI_PATH');
    expect(path, isNotEmpty);
    expect(File(path!).existsSync(), isTrue,
        reason: 'Native library must exist');
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
    final sandbox = await Directory.systemTemp.createTemp('journal-inspect-');
    try {
      final request = <String, dynamic>{
        'handle': handle,
        'journalPath': '${sandbox.path}/missing.sqlite',
        'localPath': sandbox.path,
        'relativePath': 'file',
        'revision': nodeId,
        'size': 0,
      };
      expect(await bridge.localFileMatches(request), isFalse);
      expect(await File('${sandbox.path}/missing.sqlite').exists(), isFalse);
      bridge.lock(handle);
      await expectLater(bridge.localFileMatches(request),
          throwsA(isA<NativeException>()));
    } finally {
      bridge.lock(handle);
      await sandbox.delete(recursive: true);
    }
    bridge.lock(otherUnlocked['handle'] as int);
  });
}
