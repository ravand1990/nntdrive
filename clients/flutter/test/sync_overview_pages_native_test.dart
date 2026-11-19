// Real worker-isolate ABI/loopback tests, deliberately no widget binding.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/native.dart';

void main() {
  final bridge = NativeBridge.instance;
  late Directory state;
  late Directory root;
  late HttpServer server;
  late int handle;
  late int requests;
  var failRemote = false;

  setUp(() async {
    state = await Directory.systemTemp.createTemp('overview-pages-');
    root = await Directory('${state.path}/root').create();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = 0;
    failRemote = false;
    server.listen((request) async {
      requests++;
      expect(request.method, 'GET');
      expect(request.uri.path, '/api/v1/files');
      expect(request.uri.queryParameters.keys, ['parent_id']);
      expect(
        request.uri.queryParameters['parent_id'],
        '00000000-0000-0000-0000-000000000001',
      );
      request.response.headers.contentType = ContentType.json;
      if (failRemote) {
        request.response.statusCode = 503;
        request.response.write('private server diagnostic');
      } else {
        request.response.write(jsonEncode({'files': []}));
      }
      await request.response.close();
    });
    const password = 'overview pages fixture password';
    final account = bridge.generateAccount(password);
    handle =
        bridge.unlock(jsonEncode(account['keyfile']), password)['handle']
            as int;
  });

  tearDown(() async {
    await bridge.drainSession(handle);
    bridge.lock(handle);
    await server.close(force: true);
    await state.delete(recursive: true);
  });

  Map<String, dynamic> request() => {
    'baseUrl': 'http://127.0.0.1:${server.port}',
    'token': 'fixture-token',
    'remoteRootId': '00000000-0000-0000-0000-000000000001',
    'localPath': root.path,
    'journalPath': '${state.path}/journal.sqlite',
    'deviceName': 'fixture',
    'excluded': <String>[],
  };

  void files(int count) {
    for (var i = 0; i < count; i++) {
      File('${root.path}/file-$i.txt').writeAsBytesSync(const []);
    }
  }

  test(
    'more than 20k actions reach the consumer exactly once in bounded pages',
    () async {
      files(20017);
      final seen = <String>{};
      var pages = 0;
      var terminal = false;
      await bridge.syncOverviewPagesAsync(
        handle,
        request(),
        pageSize: 127,
        onPage: (page) async {
          pages++;
          final items = page['items'] as List;
          expect(
            items.length +
                (page['skipped'] as List).length +
                (page['case_collisions'] as List).length,
            lessThanOrEqualTo(127),
          );
          expect((page['totals'] as Map)['items'], 20017);
          expect(terminal, isFalse);
          for (final item in items.cast<Map>()) {
            expect(item['kind'], 'upload');
            expect(item['case_collision'], isFalse);
            expect(seen.add(item['path'] as String), isTrue);
          }
          expect(page['delivered'], seen.length);
          terminal = page['done'] == true;
        },
      );
      expect(seen.length, 20017);
      expect(pages, greaterThan(1));
      expect(terminal, isTrue);
      expect(requests, 1, reason: 'pages must never rescan/relist');
      expect(File('${state.path}/journal.sqlite').existsSync(), isFalse);
      expect(root.listSync().length, 20017);
    },
  );

  test(
    'first publication is consumed before another page; drain waits for it',
    () async {
      files(3);
      final first = Completer<void>();
      final release = Completer<void>();
      var pages = 0;
      var cancelled = false;
      final load = bridge.syncOverviewPagesAsync(
        handle,
        request(),
        pageSize: 1,
        shouldContinue: () => !cancelled,
        onPage: (page) async {
          pages++;
          first.complete();
          expect(page['done'], isFalse);
          await release.future;
        },
      );
      await first.future;
      var drained = false;
      final drain = bridge.drainSession(handle).then((_) => drained = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(pages, 1);
      expect(drained, isFalse);
      await expectLater(
        bridge.syncOverviewPagesAsync(handle, request(), onPage: (_) async {}),
        throwsStateError,
      );
      cancelled = true;
      release.complete();
      await load;
      await drain;
      expect(drained, isTrue);
      expect(pages, 1);
    },
  );

  test(
    'consumer failure and cancellation close cursors before a retry',
    () async {
      files(3);
      await expectLater(
        bridge.syncOverviewPagesAsync(
          handle,
          request(),
          pageSize: 1,
          onPage: (_) async => throw StateError('consumer failed'),
        ),
        throwsStateError,
      );
      var cancelled = false;
      var pages = 0;
      await bridge.syncOverviewPagesAsync(
        handle,
        request(),
        pageSize: 1,
        shouldContinue: () => !cancelled,
        onPage: (_) async {
          pages++;
          cancelled = true;
        },
      );
      expect(pages, 1);
      var items = 0;
      await bridge.syncOverviewPagesAsync(
        handle,
        request(),
        onPage: (page) async {
          items += (page['items'] as List).length;
        },
      );
      expect(items, 3);
    },
  );

  test(
    'failed comparison releases admission and redacts diagnostics',
    () async {
      failRemote = true;
      await expectLater(
        bridge.syncOverviewPagesAsync(
          handle,
          request(),
          onPage: (_) async {
            fail('no partial comparison is safe after a scan/remote failure');
          },
        ),
        throwsA(
          isA<NativeException>().having(
            (e) => e.message,
            'message',
            'overview comparison unavailable',
          ),
        ),
      );
      failRemote = false;
      var pages = 0;
      await bridge.syncOverviewPagesAsync(
        handle,
        request(),
        onPage: (page) async {
          pages++;
          expect(page['done'], isTrue);
          expect(page['delivered'], 0);
        },
      );
      expect(pages, 1);
    },
  );

  test(
    'locked and pre-cancelled requests admit no native or HTTP work',
    () async {
      await bridge.syncOverviewPagesAsync(
        handle,
        request(),
        shouldContinue: () => false,
        onPage: (_) async => fail('cancelled'),
      );
      bridge.lock(handle);
      await expectLater(
        bridge.syncOverviewPagesAsync(handle, request(), onPage: (_) async {}),
        throwsA(isA<NativeException>()),
      );
      expect(requests, 0);
      expect(File('${state.path}/journal.sqlite').existsSync(), isFalse);
    },
  );
}
