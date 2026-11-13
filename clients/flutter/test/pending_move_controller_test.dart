import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/pending_moves.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class MemoryMoveStore implements PendingMoveStore {
  List<PendingMove> moves = [];

  @override
  Future<List<PendingMove>> load() async => List.of(moves);

  @override
  Future<void> save(List<PendingMove> value) async => moves = List.of(value);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory scratch;
  late MemoryMoveStore store;
  late List<SyncController> controllers;
  late List<int> flushCalls;
  var nextFlush = const PendingMoveFlush();

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('pending-moves-');
    await Directory(p.join(scratch.path, 'documents')).create(recursive: true);
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => call.method == 'getApplicationDocumentsDirectory'
          ? p.join(scratch.path, 'documents')
          : p.join(scratch.path, 'support'),
    );
    store = MemoryMoveStore();
    controllers = [];
    flushCalls = [];
    nextFlush = const PendingMoveFlush();
  });

  tearDown(() async {
    for (final controller in controllers) {
      controller.dispose();
    }
    await scratch.delete(recursive: true);
  });

  SyncController controller() {
    final controller = SyncController(
      server: 'http://unused',
      token: 'private-token',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      pendingMoves: PendingMoveQueue(store: store),
      rootsLoader: () async => const AccountRootsResult([]),
      syncRunner: (handle, request, progress) async => <String, dynamic>{
        'uploaded': 0,
        'downloaded': 0,
        'conflicts': 0,
        'errors': <dynamic>[],
      },
      pendingMoveFlusher: ({
        required ApiClient api,
        required int handle,
        required PendingMoveQueue queue,
      }) async {
        flushCalls.add(handle);
        final before = await queue.load();
        if (nextFlush.applied > 0) {
          // Stand in for a successful replay: the entries were applied.
          await queue.store.save(const []);
          return PendingMoveFlush(applied: nextFlush.applied);
        }
        return PendingMoveFlush(
          pending: before.length,
          needsAttention:
              before.where((move) => move.blockedReason != null).length,
        );
      },
    );
    controllers.add(controller);
    return controller;
  }

  RemoteFile source() =>
      RemoteFile('file-1', null, 'sealed-name', false, 10, false, 1, null);

  test('an offline move is queued and counted without plaintext', () async {
    final sync = controller();
    await sync.load();
    expect(sync.pendingMoveCount, 0);

    final message = await sync.enqueueOfflineMove(source(), 'destination');

    expect(message, contains('offline'));
    expect(store.moves.single.fileId, 'file-1');
    expect(store.moves.single.destinationParentId, 'destination');
    expect(sync.pendingMoveCount, 1);
    expect(sync.pendingMoveAttention, 0);
  });

  test('the queue is replayed on unlock and on sync all', () async {
    final sync = controller();
    await sync.load();
    await sync.enqueueOfflineMove(source(), 'destination');
    final loadCalls = flushCalls.length;

    nextFlush = const PendingMoveFlush(applied: 1);
    await sync.syncAll();

    expect(flushCalls.length, greaterThan(loadCalls));
    expect(sync.pendingMoveCount, 0);
    expect(store.moves, isEmpty);
    expect(sync.lastStatus, contains('Applied 1 queued move(s).'));
  });

  test('a queued move needing attention can be discarded', () async {
    final sync = controller();
    await sync.load();
    await sync.enqueueOfflineMove(source(), 'destination');
    store.moves = [store.moves.single.blocked('changed on another device')];
    await sync.refreshPendingMoves();
    expect(sync.pendingMoveAttention, 1);

    await sync.discardPendingMoves();

    expect(store.moves, isEmpty);
    expect(sync.pendingMoveCount, 0);
    expect(sync.pendingMoveAttention, 0);
  });
}
