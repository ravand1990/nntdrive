import 'dart:async';
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
  test('reference backfill drain waits for the complete HTTP worker', () async {
    final bridge = NativeBridge.instance;
    const password = 'drain backfill fixture password';
    final keys = bridge.generateAccount(password);
    final handle = bridge.unlock(jsonEncode(keys['keyfile']), password)['handle'] as int;
    final entered = Completer<void>();
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requests = 0;
    server.listen((request) async {
      requests++;
      entered.complete();
      await release.future;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"versions":[],"next":null}');
      await request.response.close();
    });
    final url = 'http://127.0.0.1:${server.port}';
    final worker = bridge.backfillReferencesAsync(handle, url, 'fixture-token');
    try {
      await entered.future.timeout(const Duration(seconds: 30));
      var drained = false;
      final drain = bridge.drainSession(handle).then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      await expectLater(bridge.backfillReferencesAsync(handle, url, 'fixture-token'),
          throwsStateError);
      expect(requests, 1);
      release.complete();
      expect((await worker)['failed'], false);
      await drain;
      expect(drained, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      await worker;
      await bridge.drainSession(handle);
      bridge.lock(handle);
      await server.close(force: true);
    }
  });

  test('local equality worker completes before session drain returns', () async {
    final bridge = NativeBridge.instance;
    // Missing request fields fail inside the native worker, not on this isolate.
    const handle = 900000002;
    var finished = false;
    final worker = bridge.localFileMatches({'handle': handle}).then<void>(
      (_) { finished = true; },
      onError: (Object error) {
        expect(error, isA<NativeException>());
        finished = true;
      },
    );
    await bridge.drainSession(handle);
    expect(finished, isTrue);
    await worker;
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

  test(
      'drained native sessions reject all new async workers before network access',
      () async {
    final bridge = NativeBridge.instance;
    const handle = 900000001;
    await bridge.drainSession(handle);
    await expectLater(bridge.backfillReferencesAsync(handle, '', ''),
        throwsStateError);
    await expectLater(bridge.copyFileAsync(handle, {}), throwsStateError);
    await expectLater(bridge.localFileMatches({'handle': handle}),
        throwsStateError);
    await expectLater(bridge.syncRequestAsync(handle, {}), throwsStateError);
    await expectLater(
        bridge.syncRunAsync(
            handle: handle,
            baseUrl: '',
            token: '',
            remoteRootId: '',
            localPath: '',
            journalPath: '',
            deviceName: ''),
        throwsStateError);
    await expectLater(
        bridge.uploadAsync(
            handle: handle,
            baseUrl: '',
            token: '',
            fileId: '',
            revisionId: '',
            parentRevision: '',
            path: ''),
        throwsStateError);
    await expectLater(
        bridge.downloadAsync(
            handle: handle,
            baseUrl: '',
            token: '',
            fileId: '',
            revisionId: '',
            destination: ''),
        throwsStateError);
  });
  test('native worker wrappers still cross isolates and report native failures',
      () async {
    final bridge = NativeBridge.instance;
    await expectLater(
        bridge.syncRunAsync(
            handle: 0,
            baseUrl: '',
            token: '',
            remoteRootId: '',
            localPath: '',
            journalPath: '',
            deviceName: ''),
        throwsA(isA<NativeException>()));
    await expectLater(
        bridge.uploadAsync(
            handle: 0,
            baseUrl: '',
            token: '',
            fileId: '',
            revisionId: '',
            parentRevision: '',
            path: ''),
        throwsA(isA<NativeException>()));
    await expectLater(
        bridge.downloadAsync(
            handle: 0,
            baseUrl: '',
            token: '',
            fileId: '',
            revisionId: '',
            destination: ''),
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
