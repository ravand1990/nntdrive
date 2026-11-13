import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/pending_moves.dart';

class MemoryMoveStore implements PendingMoveStore {
  List<PendingMove> moves = [];
  int saves = 0;

  @override
  Future<List<PendingMove>> load() async => List.of(moves);

  @override
  Future<void> save(List<PendingMove> value) async {
    moves = List.of(value);
    saves++;
  }
}

void main() {
  PendingMove sample({
    String entryId = 'entry-1',
    String fileId = 'file-1',
    String? sourceParentId = 'source-parent',
    String destinationParentId = 'destination',
    String? blockedReason,
  }) =>
      PendingMove(
        entryId: entryId,
        fileId: fileId,
        sourceParentId: sourceParentId,
        sourceNameEnc: 'sealed-name',
        destinationParentId: destinationParentId,
        isDir: false,
        queuedAt: DateTime.utc(2026, 11, 13, 9),
        blockedReason: blockedReason,
      );

  group('queued offline moves', () {
    test('store only opaque IDs and sealed names', () {
      final json = sample().toJson();
      expect(json.keys.toSet(), {
        'entryId',
        'fileId',
        'sourceParentId',
        'sourceNameEnc',
        'destinationParentId',
        'isDir',
        'queuedAt',
        'blockedReason',
      });
      expect(jsonEncode(json), contains('sealed-name'));
      expect(jsonEncode(json), isNot(contains('report.pdf')));
      final roundTrip = PendingMove.fromJson(jsonDecode(jsonEncode(json)))!;
      expect(roundTrip.fileId, 'file-1');
      expect(roundTrip.destinationParentId, 'destination');
      expect(roundTrip.queuedAt, DateTime.utc(2026, 11, 13, 9));
    });

    test('drops malformed and hand-edited entries', () {
      expect(PendingMove.fromJson(null), isNull);
      expect(PendingMove.fromJson('nope'), isNull);
      expect(PendingMove.fromJson({'entryId': 'e'}), isNull);
      expect(
          PendingMove.fromJson(sample().toJson()..['queuedAt'] = 'x'), isNull);
      expect(PendingMove.fromJson(sample().toJson()..['sourceNameEnc'] = ''),
          isNull);
    });

    test('one entry per item, bounded in size', () async {
      final store = MemoryMoveStore();
      final queue = PendingMoveQueue(store: store, limit: 1);
      final file = RemoteFile(
          'file-1', 'source-parent', 'sealed', false, 1, false, 1, null);
      expect(
          await queue.enqueue(file: file, destinationParentId: 'destination'),
          PendingMoveAdd.added);
      expect(await queue.enqueue(file: file, destinationParentId: 'other'),
          PendingMoveAdd.duplicate);
      expect(
          await queue.enqueue(
              file: RemoteFile(
                  'file-2', null, 'sealed', false, 1, false, 1, null),
              destinationParentId: 'destination'),
          PendingMoveAdd.full);
      expect(store.moves, hasLength(1));
    });

    test('refuses an out-of-range queue limit', () {
      expect(() => PendingMoveQueue(store: MemoryMoveStore(), limit: 0),
          throwsArgumentError);
      expect(
          () => PendingMoveQueue(
              store: MemoryMoveStore(), limit: pendingMoveLimit + 1),
          throwsArgumentError);
    });

    test('discarding blocked entries keeps the rest', () async {
      final store = MemoryMoveStore()
        ..moves = [
          sample(entryId: 'a'),
          sample(entryId: 'b', fileId: 'file-2', blockedReason: 'changed')
        ];
      await PendingMoveQueue(store: store).discardBlocked();
      expect(store.moves.map((m) => m.entryId), ['a']);
    });
  });

  group('replaying queued moves', () {
    late NativeBridge bridge;
    late int handle;
    late HttpServer server;
    late ApiClient api;
    late List<Map<String, dynamic>> writes;
    late List<String> reads;
    late List<Map<String, dynamic>> rows;
    late int status;

    setUp(() async {
      bridge = NativeBridge.instance;
      final keys = bridge.generateAccount('pending move password');
      handle = bridge.unlock(
              jsonEncode(keys['keyfile']), 'pending move password')['handle']
          as int;
      writes = [];
      reads = [];
      rows = [];
      status = 200;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        if (request.method == 'GET') {
          reads.add(request.uri.queryParameters['parent_id'] ?? 'root');
          request.response.write(jsonEncode({'files': rows}));
        } else {
          writes.add(jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>);
          request.response.statusCode = status;
          request.response.write('{}');
        }
        await request.response.close();
      });
      api =
          ApiClient(baseUrl: 'http://127.0.0.1:${server.port}', token: 'test');
    });

    tearDown(() async {
      try {
        bridge.lock(handle);
      } catch (_) {}
      await server.close(force: true);
    });

    Future<PendingMoveFlush> flush(PendingMoveStore store) => flushPendingMoves(
        api: api, handle: handle, queue: PendingMoveQueue(store: store));

    test('applies a queued move and clears the queue', () async {
      const fileId = '3b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const destination = '4b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final sealed = bridge.sealName(handle, fileId, 'report.pdf');
      final store = MemoryMoveStore()
        ..moves = [
          PendingMove(
            entryId: 'entry-1',
            fileId: fileId,
            sourceParentId: null,
            sourceNameEnc: sealed,
            destinationParentId: destination,
            isDir: false,
            queuedAt: DateTime.utc(2026, 11, 13, 9),
          )
        ];

      final result = await flush(store);

      expect(result.applied, 1);
      expect(result.pending, 0);
      expect(result.offline, isFalse);
      expect(store.moves, isEmpty);
      expect(writes, hasLength(1));
      expect(writes.single['parent_id'], destination);
      expect(writes.single['source_name_enc'], sealed);
      expect(jsonEncode(writes), isNot(contains('report.pdf')));
    });

    test('an unacknowledged attempt that already landed is not applied twice',
        () async {
      const fileId = '5b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final sealed = bridge.sealName(handle, fileId, 'landed.txt');
      rows = [
        {'id': fileId, 'name_enc': sealed, 'is_dir': false}
      ];
      final store = MemoryMoveStore()
        ..moves = [
          PendingMove(
            entryId: 'entry-1',
            fileId: fileId,
            sourceParentId: null,
            sourceNameEnc: sealed,
            destinationParentId: 'destination',
            isDir: false,
            queuedAt: DateTime.utc(2026, 11, 13, 9),
          )
        ];

      final result = await flush(store);

      expect(result.applied, 1);
      expect(writes, isEmpty);
      expect(store.moves, isEmpty);
    });

    test('a destination collision stops safely and stops retrying', () async {
      const fileId = '6b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      const sibling = '7b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final sealed = bridge.sealName(handle, fileId, 'Cafe\u0301.txt');
      rows = [
        {
          'id': sibling,
          'name_enc': bridge.sealName(handle, sibling, 'CAFÉ.TXT')
        }
      ];
      final store = MemoryMoveStore()
        ..moves = [
          PendingMove(
            entryId: 'entry-1',
            fileId: fileId,
            sourceParentId: null,
            sourceNameEnc: sealed,
            destinationParentId: 'destination',
            isDir: false,
            queuedAt: DateTime.utc(2026, 11, 13, 9),
          )
        ];

      final result = await flush(store);

      expect(result.applied, 0);
      expect(result.needsAttention, 1);
      expect(result.problems.single, contains('already exists'));
      expect(writes, isEmpty);
      expect(store.moves.single.blockedReason, isNotNull);

      final readsBefore = reads.length;
      final second = await flush(store);
      expect(second.applied, 0);
      expect(second.needsAttention, 1);
      expect(reads.length, readsBefore,
          reason: 'blocked entries stop retrying');
    });

    test('a server-side source change keeps the entry and reports it',
        () async {
      const fileId = '8b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final sealed = bridge.sealName(handle, fileId, 'raced.txt');
      status = 409;
      final store = MemoryMoveStore()
        ..moves = [
          PendingMove(
            entryId: 'entry-1',
            fileId: fileId,
            sourceParentId: null,
            sourceNameEnc: sealed,
            destinationParentId: 'destination',
            isDir: false,
            queuedAt: DateTime.utc(2026, 11, 13, 9),
          )
        ];

      final result = await flush(store);

      expect(result.applied, 0);
      expect(result.needsAttention, 1);
      expect(store.moves, hasLength(1));
      expect(writes, hasLength(1));
    });

    test('an unreachable server keeps every entry in order', () async {
      final store = MemoryMoveStore()
        ..moves = [
          sample(entryId: 'a'),
          sample(entryId: 'b', fileId: 'file-2')
        ];
      final offlineApi =
          ApiClient(baseUrl: 'http://127.0.0.1:1', token: 'test');

      final result = await flushPendingMoves(
          api: offlineApi,
          handle: handle,
          queue: PendingMoveQueue(store: store));

      expect(result.offline, isTrue);
      expect(result.pending, 2);
      expect(store.moves.map((m) => m.entryId), ['a', 'b']);
    });

    test('a deleted item is dropped without retrying', () async {
      const fileId = '9b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';
      final sealed = bridge.sealName(handle, fileId, 'gone.txt');
      status = 404;
      final store = MemoryMoveStore()
        ..moves = [
          PendingMove(
            entryId: 'entry-1',
            fileId: fileId,
            sourceParentId: null,
            sourceNameEnc: sealed,
            destinationParentId: 'destination',
            isDir: false,
            queuedAt: DateTime.utc(2026, 11, 13, 9),
          )
        ];

      final result = await flush(store);

      expect(result.pending, 0);
      expect(result.problems.single, contains('no longer exists'));
      expect(store.moves, isEmpty);
    });

    test('a locked session keeps the queue for the next unlock', () async {
      final store = MemoryMoveStore()..moves = [sample()];
      bridge.lock(handle);

      final result = await flush(store);

      expect(result.locked, isTrue);
      expect(result.pending, 1);
      expect(store.moves, hasLength(1));
      expect(writes, isEmpty);
    });
  });
}
