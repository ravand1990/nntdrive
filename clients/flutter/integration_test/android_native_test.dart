import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:integration_test/integration_test.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/storage_access.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android real storage channel keeps private sync permission-free',
      (tester) async {
    const access = StorageAccess();
    final path = await access.privateFolder();
    expect(path, isNotNull);
    final support = await getApplicationSupportDirectory();
    final journalRoot =
        await Directory('${support.path}/sync').create(recursive: true);
    final dataRoot = await Directory(path!).resolveSymbolicLinks();
    final journals = await journalRoot.resolveSymbolicLinks();
    expect(dataRoot, isNot(journals));
    expect(dataRoot.startsWith('$journals/'), isFalse);
    expect(journals.startsWith('$dataRoot/'), isFalse);
    expect(await access.permissionRequired(path), isFalse);
    await access.check(path);
    final file = File('$path/access-smoke');
    try {
      await file.writeAsString('private local fixture');
      expect(await file.readAsString(), 'private local fixture');
    } finally {
      if (await file.exists()) await file.delete();
    }
    await expectLater(
        access.permissionRequired('content://unsupported/tree/example'),
        throwsA(isA<PlatformException>()));
    // Fresh hosted emulator has no all-files grant. No check opens settings.
    expect(await access.permissionRequired('/storage/emulated/0'), isTrue);
  });

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
