import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_disk_usage.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

class WorkerRoots extends ListBase<String> {
  WorkerRoots(this.path) : caller = Isolate.current.hashCode;
  final String path;
  final int caller;
  @override
  int get length {
    if (Isolate.current.hashCode == caller) throw StateError('caller read');
    return 1;
  }

  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  String operator [](int index) => path;
  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('immutable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late Directory root;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('sync-disk-test-');
    // Match the existing confinement fixtures: temp paths may use aliases or
    // noncanonical spellings on Windows/macOS. Production rejects those paths.
    temp = Directory(await temp.resolveSymbolicLinks());
    root = await Directory(p.join(temp.path, 'root')).create();
  });
  tearDown(() => temp.delete(recursive: true));

  Future<SyncDiskRootUsage> read({int maxEntries = 10000}) async =>
      (await runSyncDiskUsage([
        root.path,
      ], maxEntries: maxEntries)).roots.single;

  test(
    'real lengths refresh without opening corrupt journal or changing files',
    () async {
      final file = File(p.join(root.path, 'private-name'));
      await file.writeAsBytes([1, 2, 3]);
      await File(p.join(root.path, '.hidden')).writeAsBytes([]);
      final excluded = await Directory(p.join(root.path, 'excluded')).create();
      await File(p.join(excluded.path, 'local-only')).writeAsBytes([4, 5]);
      final journal = File(p.join(temp.path, 'journal.sqlite'));
      await journal.writeAsString('not a database');
      final before = await journal.stat();
      final first = await read();
      expect(first.state, SyncDiskState.complete);
      expect(first.bytes, 5);
      expect(first.files, 3);
      await file.writeAsBytes([1]);
      expect((await read()).bytes, 3);
      await file.delete();
      expect((await read()).bytes, 2);
      expect(await journal.readAsString(), 'not a database');
      expect((await journal.stat()).modified, before.modified);
      expect(await excluded.exists(), isTrue);
      expect((await temp.list().toList()).length, 2);
    },
  );

  test(
    'missing/file/relative/traversal roots are unavailable not zero totals',
    () async {
      final file = await File(
        p.join(temp.path, 'file'),
      ).writeAsString('secret');
      for (final path in [
        p.join(temp.path, 'missing'),
        file.path,
        'relative',
        '${root.path}${p.separator}..${p.separator}root',
      ]) {
        final result = (await runSyncDiskUsage([path])).roots.single;
        expect(result.state, SyncDiskState.unavailable, reason: path);
        expect(result.bytes, 0);
      }
    },
  );

  test(
    'equal/nested roots refuse both rows; adjacent sibling is independent',
    () async {
      final child = await Directory(p.join(root.path, 'child')).create();
      final sibling = await Directory('${root.path}-sibling').create();
      await File(p.join(sibling.path, 'f')).writeAsBytes([1, 2]);
      final result = await runSyncDiskUsage([
        root.path,
        child.path,
        root.path,
        sibling.path,
      ]);
      expect(
        result.roots.take(3).map((r) => r.state),
        everyElement(SyncDiskState.overlap),
      );
      expect(result.roots.last.state, SyncDiskState.complete);
      expect(result.roots.last.bytes, 2);
    },
  );

  test(
    'links roots ancestors nested directories files and cycles never counted',
    () async {
      final outside = await Directory(p.join(temp.path, 'outside')).create();
      await File(
        p.join(outside.path, 'secret'),
      ).writeAsBytes(List.filled(100, 1));
      final alias = await Link(p.join(temp.path, 'alias')).create(root.path);
      final nested = await Directory(p.join(root.path, 'nested')).create();
      await Link(p.join(root.path, 'escape')).create(outside.path);
      await Link(
        p.join(root.path, 'file-link'),
      ).create(p.join(outside.path, 'secret'));
      await Link(p.join(root.path, 'cycle')).create(root.path);
      await File(p.join(nested.path, 'f')).writeAsBytes([1, 2, 3]);
      final result = await read();
      expect(result.bytes, 3);
      expect(result.files, 1);
      expect(result.skipped, 3);
      expect(result.state, SyncDiskState.incomplete);
      for (final path in [alias.path, p.join(alias.path, 'nested')]) {
        expect(
          (await runSyncDiskUsage([path])).roots.single.state,
          SyncDiskState.unavailable,
        );
      }
      await File(p.join(nested.path, 'f')).delete();
      await Link(
        p.join(nested.path, 'f'),
      ).create(p.join(outside.path, 'secret'));
      expect((await read()).bytes, 0);
      expect(await File(p.join(outside.path, 'secret')).length(), 100);
    },
    skip: Platform.isWindows
        ? 'symlink privilege fixture; installed acceptance #207'
        : false,
  );

  test(
    'entry/time/root bounds return explicit incompleteness and bounded output',
    () async {
      for (var i = 0; i < 8; i++) {
        await File(p.join(root.path, '$i')).writeAsBytes([1]);
      }
      final limited = await read(maxEntries: 2);
      expect(limited.state, SyncDiskState.incomplete);
      expect(limited.files, 2);
      expect(limited.bytes, 2);
      final zero = (await runSyncDiskUsage([
        root.path,
      ], maxTime: Duration.zero)).roots.single;
      expect(zero.state, SyncDiskState.incomplete);
      expect(zero.files, 0);
      await expectLater(
        runSyncDiskUsage(List.filled(21, root.path)),
        throwsStateError,
      );
      expect((await runSyncDiskUsage([])).roots, isEmpty);
    },
  );

  test(
    'production worker consumes roots off caller and yields an event turn',
    () async {
      var yielded = false;
      Timer.run(() => yielded = true);
      final result = await runSyncDiskUsage(WorkerRoots(root.path));
      expect(result.roots.single.state, SyncDiskState.complete);
      expect(yielded, isTrue);
    },
  );

  Future<SyncController> controller() async {
    SharedPreferences.setMockInitialValues({});
    final sync = SyncController(
      server: 'http://unused',
      token: '',
      handle: 0,
      api: ApiClient(baseUrl: 'http://unused'),
      rootsLoader: () async => const AccountRootsResult([]),
    );
    addTearDown(sync.dispose);
    await sync.load();
    sync.folders.add(
      SyncFolderConfig(
        id: 'r',
        name: 'private',
        localPath: root.path,
        remoteRootId: 'opaque',
      ),
    );
    return sync;
  }

  test(
    'controller dispatches real worker without network journal or native access',
    () async {
      final sync = await controller();
      await File(p.join(root.path, 'f')).writeAsBytes([1, 2]);
      expect((await sync.measureSyncDiskUsage()).roots.single.bytes, 2);
      expect((await root.list().toList()).length, 1);
    },
  );

  test(
    'single flight refresh close rejects late result and drains admitted worker',
    () async {
      final sync = await controller();
      final gate = Completer<SyncDiskUsage>();
      var calls = 0;
      final first = sync.measureSyncDiskUsage(
        runner: (paths) {
          calls++;
          expect(paths, [root.path]);
          return gate.future;
        },
      );
      final second = sync.measureSyncDiskUsage(
        runner: (_) => throw StateError('second scan'),
      );
      final rejected = expectLater(first, throwsStateError);
      final rejectedSecond = expectLater(second, throwsStateError);
      var drained = false;
      final drain = sync.stopAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      await expectLater(sync.measureSyncDiskUsage(), throwsStateError);
      expect(calls, 1);
      gate.complete(SyncDiskUsage([]));
      await Future.wait([rejected, rejectedSecond, drain]);
      expect(drained, isTrue);
    },
  );

  test(
    'changed root/removal discards observation and failure permits retry',
    () async {
      final sync = await controller();
      for (final remove in [false, true]) {
        final gate = Completer<SyncDiskUsage>();
        final pending = sync.measureSyncDiskUsage(runner: (_) => gate.future);
        final rejected = expectLater(pending, throwsStateError);
        if (remove) {
          sync.folders.clear();
        } else {
          sync.folders.single.localPath = p.join(temp.path, 'changed');
        }
        gate.complete(SyncDiskUsage([]));
        await rejected;
      }
      expect((await sync.measureSyncDiskUsage()).roots, isEmpty);
    },
  );
}
