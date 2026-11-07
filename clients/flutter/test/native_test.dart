import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/native.dart';

void main() {
  test('bounded backfill uses worker isolate and rejects locked handles before HTTP', () async {
    for (var i = 0; i < 2; i++) {
      await expectLater(
        NativeBridge.instance.backfillReferencesAsync(0, 'http://127.0.0.1:1', 'secret'),
        throwsA(isA<NativeException>()),
      );
    }
  });
  test('backfill native success and HTTP failure are retryable with token-only requests', () async {
    final bridge = NativeBridge.instance;
    final account = bridge.generateAccount('backfill test password');
    final handle = bridge.unlock(jsonEncode(account['keyfile']), 'backfill test password')['handle'] as int;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var fail = true;
    var requests = 0;
    server.listen((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v1/reference-backfill');
      expect(request.headers.value('authorization'), 'Bearer scoped-test-token');
      expect(await utf8.decoder.bind(request).join(), isEmpty);
      request.response.statusCode = fail ? 503 : 200;
      request.response.headers.contentType = ContentType.json;
      request.response.write(fail ? '{"error":"private backend detail"}' : '{"versions":[],"next":null}');
      await request.response.close();
    });
    try {
      final url = 'http://127.0.0.1:${server.port}';
      final failed = await bridge.backfillReferencesAsync(handle, url, 'scoped-test-token');
      expect(failed['failed'], true);
      expect(failed['completed'], 0);
      expect(failed.toString(), isNot(contains('private backend detail')));
      fail = false;
      final success = await bridge.backfillReferencesAsync(handle, url, 'scoped-test-token');
      expect(success['failed'], false);
      expect(success['more'], false);
      expect(requests, 2);
    } finally {
      bridge.lock(handle);
      await server.close(force: true);
    }
  });
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
  test('native bridge creates keys and seals names', () {
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
    bridge.lock(handle);
    bridge.lock(otherUnlocked['handle'] as int);
  });
}
