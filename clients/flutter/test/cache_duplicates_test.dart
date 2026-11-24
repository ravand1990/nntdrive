import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/cache_duplicates.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late DownloadCache cache;
  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('cache-duplicates');
    dir = Directory(await temp.resolveSymbolicLinks());
    cache = DownloadCache(root: Directory(p.join(dir.path, 'cache')));
    await cache.open();
  });
  tearDown(() => dir.delete(recursive: true));

  Future<CachedDownload> store(
    String id,
    List<int> bytes, {
    bool pin = false,
  }) async {
    final source = File(p.join(dir.path, 'source'));
    await source.writeAsBytes(bytes);
    return cache.store(
      fileId: id,
      revisionId: 'r',
      source: source,
      pinned: pin,
    );
  }

  test('exact bytes, different same-length bytes and empty files', () async {
    await store('a', [1, 2], pin: true);
    await store('b', [1, 2]);
    await store('c', [1, 3]);
    await store('empty-a', []);
    await store('empty-b', []);
    final result = await cache.reviewDuplicates();
    expect(result.partial, false);
    expect(result.groups.map((g) => g.map((e) => e.fileId).toSet()).toList(), [
      {'a', 'b'},
      {'empty-a', 'empty-b'},
    ]);
    expect(result.groups.first.first.pinned, true);
    expect(result.excluded, 0);
    // Three two-byte hashes plus both sides of the exact comparison.
    expect(result.bytesRead, 3 * 2 + 2 * 2);
  });

  test(
    'size drift, missing, link and directory rejected without writes',
    () async {
      await store('good-a', [7]);
      await store('good-b', [7]);
      final drift = await store('drift', [7]);
      final missing = await store('missing', [7]);
      final link = await store('link', [7]);
      final directory = await store('directory', [7]);
      await cache.fileFor(drift).writeAsBytes([7, 7]);
      await cache.fileFor(missing).delete();
      await cache.fileFor(link).delete();
      await Link(cache.fileFor(link).path).create(cache.fileFor(drift).path);
      await cache.fileFor(directory).delete();
      await Directory(cache.fileFor(directory).path).create();
      final index = File(p.join(cache.root.path, 'index.json'));
      final before = await index.readAsBytes();
      final scratch = File(p.join(cache.root.path, 'retained.part'));
      await scratch.writeAsString('untouched');
      final result = await cache.reviewDuplicates();
      expect(result.groups.single.map((e) => e.fileId), ['good-a', 'good-b']);
      expect(result.excluded, 4);
      expect(result.partial, true);
      expect(await index.readAsBytes(), before);
      expect(await scratch.readAsString(), 'untouched');
      expect(cache.entryCount, 6);
      expect(await cache.fileFor(drift).readAsBytes(), [7, 7]);
    },
    skip: Platform.isWindows ? 'Symlink privilege required' : false,
  );

  test('entry byte time and output caps report partial honestly', () async {
    for (var i = 0; i < 6; i++) {
      await store('$i', [i ~/ 2]);
    }
    expect(
      (await cache.reviewDuplicates(
        limits: const DuplicateLimits(maxEntries: 1),
      )).partial,
      true,
    );
    final bytes = await cache.reviewDuplicates(
      limits: const DuplicateLimits(maxBytes: 1),
    );
    expect(bytes.partial, true);
    expect(bytes.bytesRead, lessThanOrEqualTo(1));
    expect(bytes.groups, isEmpty);
    expect(
      (await cache.reviewDuplicates(
        limits: const DuplicateLimits(maxTime: Duration.zero),
      )).partial,
      true,
    );
    final output = await cache.reviewDuplicates(
      limits: const DuplicateLimits(maxGroups: 1, maxRows: 2),
    );
    expect(output.groups.length, 1);
    expect(output.groups.single.length, 2);
    expect(output.partial, true);
  });

  test(
    'queue holds admitted scan, pins serialize and root links fail closed',
    () async {
      await store('a', [1]);
      await store('b', [1]);
      final entered = Completer<void>();
      final release = Completer<void>();
      final review = cache.reviewDuplicates(
        runner: (root, entries, limits) async {
          entered.complete();
          await release.future;
          return runCacheDuplicateReview(root, entries, limits);
        },
      );
      await entered.future;
      var pinned = false;
      final pin = cache.setPinned('a', 'r', true).then((_) => pinned = true);
      await Future<void>.delayed(Duration.zero);
      expect(pinned, false);
      release.complete();
      expect((await review).groups.first.first.pinned, false);
      await pin;
      expect(cache.find('a')!.pinned, true);
      final moved = '${cache.root.path}-moved';
      await cache.root.rename(moved);
      await Link(cache.root.path).create(moved);
      await expectLater(cache.reviewDuplicates(), throwsStateError);
    },
    skip: Platform.isWindows ? 'Symlink privilege required' : false,
  );

  test('same-length content changed during observation is excluded', () async {
    final a = await store('a', [1]);
    final b = await store('b', [2]);
    final result = await runCacheDuplicateReview(cache.root.path, [
      a,
      ChangingDownload(b, cache.fileFor(b).path),
    ], const DuplicateLimits());
    expect(result.groups, isEmpty);
    expect(result.excluded, 1);
    expect(result.partial, true);
    expect(await cache.fileFor(b).readAsBytes(), [1]);
  });

  test(
    'linked ancestor fails closed and does not consume indexed content',
    () async {
      await store('a', [1]);
      await store('b', [1]);
      final original = dir.path;
      final moved = '$original-moved';
      await dir.rename(moved);
      try {
        await Link(original).create(moved);
        await expectLater(cache.reviewDuplicates(), throwsStateError);
      } finally {
        await Link(original).delete();
        await Directory(moved).rename(original);
      }
    },
    skip: Platform.isWindows ? 'Symlink privilege required' : false,
  );

  test('unopened and corrupt index never reconcile', () async {
    await expectLater(
      DownloadCache(root: cache.root).reviewDuplicates(),
      throwsStateError,
    );
    await File(p.join(cache.root.path, 'index.json')).writeAsString('broken');
    await cache.open();
    final scratch = File(p.join(cache.root.path, 'stay.part'));
    await scratch.writeAsString('stay');
    await expectLater(cache.reviewDuplicates(), throwsStateError);
    expect(await scratch.readAsString(), 'stay');
  });

  test('worker yields for a single ordinary indexed copy', () async {
    final a = await store('a', [1]);
    var turn = false;
    Timer.run(() => turn = true);
    await runCacheDuplicateReview(cache.root.path, [
      a,
    ], const DuplicateLimits());
    expect(turn, true);
  });

  test('worker executes off caller isolate and yields an event turn', () async {
    final a = await store('a', [1]);
    final b = await store('b', [1]);
    var turn = false;
    Timer.run(() => turn = true);
    final result = await runCacheDuplicateReview(cache.root.path, [
      GuardedDownload(a, Isolate.current.hashCode),
      b,
    ], const DuplicateLimits());
    expect(result.groups, hasLength(1));
    expect(turn, true);
  });
}

class ChangingDownload extends CachedDownload {
  ChangingDownload(CachedDownload e, this.path)
    : super(
        fileId: e.fileId,
        revisionId: e.revisionId,
        fileName: e.fileName,
        sizeBytes: e.sizeBytes,
        storedAt: e.storedAt,
        lastUsedAt: e.lastUsedAt,
        pinned: e.pinned,
      );
  final String path;
  bool changed = false;
  @override
  int get sizeBytes {
    if (!changed) {
      changed = true;
      // _copySafe has already taken its pre-read stat. Simulate a same-length
      // edit at this boundary; post-read validation must reject it.
      File(path).writeAsBytesSync([1]);
      File(path).setLastModifiedSync(DateTime.utc(2000));
    }
    return super.sizeBytes;
  }
}

class GuardedDownload extends CachedDownload {
  GuardedDownload(CachedDownload e, this.caller)
    : super(
        fileId: e.fileId,
        revisionId: e.revisionId,
        fileName: e.fileName,
        sizeBytes: e.sizeBytes,
        storedAt: e.storedAt,
        lastUsedAt: e.lastUsedAt,
        pinned: e.pinned,
      );
  final int caller;
  @override
  String get fileName {
    if (Isolate.current.hashCode == caller) throw StateError('caller read');
    return super.fileName;
  }
}
