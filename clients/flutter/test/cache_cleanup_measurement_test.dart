import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:path/path.dart' as p;

class DeleteFailingFile extends Fake implements File {
  DeleteFailingFile(this.real);
  final File real;
  @override
  String get path => real.path;
  @override
  Future<int> length() => real.length();
  @override
  Future<File> delete({bool recursive = false}) async =>
      throw const FileSystemException('injected device deletion failure');
}

class DeleteFailingCache extends DownloadCache {
  DeleteFailingCache({required super.root});
  bool failDelete = false;
  @override
  File fileFor(CachedDownload entry) {
    final file = super.fileFor(entry);
    return failDelete ? DeleteFailingFile(file) : file;
  }
}

void main() {
  late Directory sandbox;
  late DownloadCache cache;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('cache-cleanup');
    cache = DeleteFailingCache(root: Directory(p.join(sandbox.path, 'cache')));
    await cache.open();
  });
  tearDown(() => sandbox.delete(recursive: true));

  Future<CachedDownload> store(
    String revision,
    int bytes, {
    bool pinned = false,
  }) async {
    final source = File(p.join(sandbox.path, 'source'));
    await source.writeAsBytes(List.filled(bytes, 7));
    return cache.store(
      fileId: 'opaque',
      revisionId: revision,
      source: source,
      pinned: pinned,
    );
  }

  test('failed deletes retain real bytes and index for retry', () async {
    final entry = await store('one', 9);
    (cache as DeleteFailingCache).failDelete = true;
    final result = await cache.clearUnpinned();
    expect(
      (result.removedEntries, result.freedBytes, result.failedEntries),
      (0, 0, 1),
    );
    expect(await File(cache.fileFor(entry).path).length(), 9);
    expect(cache.entryCount, 1);
    (cache as DeleteFailingCache).failDelete = false;
    await cache.open();
    expect(cache.entryCount, 1, reason: 'failed copy persists in the index');
    final retry = await cache.clearUnpinned();
    expect((retry.removedEntries, retry.freedBytes), (1, 9));
  });

  test(
    'cleanup counts measured deleted copies, not stale sizes or missing rows',
    () async {
      final pinned = await store('pin', 9, pinned: true);
      final changed = await store('changed', 4);
      final missing = await store('missing', 8);
      await store('empty', 0);
      await cache.fileFor(changed).writeAsBytes(List.filled(17, 1));
      await cache.fileFor(missing).delete();
      final scratch = File(p.join(cache.root.path, 'scratch.part'));
      final orphan = File(p.join(cache.root.path, '${'a' * 32}.bin'));
      await scratch.writeAsString('scratch');
      await orphan.writeAsString('orphan');
      final result = await cache.clearUnpinned();
      expect((result.removedEntries, result.freedBytes), (2, 17));
      expect((result.keptPinnedEntries, result.failedEntries), (1, 0));
      expect(await cache.fileFor(pinned).length(), 9);
      expect(await cache.fileFor(changed).exists(), isFalse);
      expect(await scratch.readAsString(), 'scratch');
      expect(await orphan.readAsString(), 'orphan');
      expect((await cache.measureUsage()).bytes, 9);
      expect(cache.entries.single.pinned, isTrue);
      final again = await cache.clearUnpinned();
      expect((again.removedEntries, again.freedBytes), (0, 0));
      // Reopen only after removing intentionally unindexed fixtures.
      await scratch.delete();
      await orphan.delete();
      await cache.open();
      expect(cache.entries.single.pinned, isTrue);
    },
  );

  test(
    'unsafe replacements are retained for retry and targets stay untouched',
    () async {
      final linked = await store('linked', 5);
      final directory = await store('directory', 8);
      final target = File(p.join(sandbox.path, 'outside'));
      await target.writeAsString('outside');
      await cache.fileFor(linked).delete();
      await Link(cache.fileFor(linked).path).create(target.path);
      await cache.fileFor(directory).delete();
      await Directory(cache.fileFor(directory).path).create();
      var result = await cache.clearUnpinned();
      expect(
        (result.removedEntries, result.freedBytes, result.failedEntries),
        (0, 0, 2),
      );
      expect(cache.entryCount, 2);
      expect(await target.readAsString(), 'outside');
      expect(await Link(cache.fileFor(linked).path).exists(), isTrue);
      await Link(cache.fileFor(linked).path).delete();
      await Directory(cache.fileFor(directory).path).delete();
      await cache.fileFor(directory).writeAsString('retry');
      result = await cache.clearUnpinned();
      expect(
        (result.removedEntries, result.freedBytes, result.failedEntries),
        (1, 5, 0),
      );
      expect(cache.entryCount, 0);
    },
    skip: Platform.isWindows ? 'Symlink privilege required' : false,
  );

  test('queued pin is honored and linked cache roots reject cleanup', () async {
    final entry = await store('one', 9);
    final pin = cache.setPinned('opaque', 'one', true);
    final clear = cache.clearUnpinned();
    await pin;
    expect((await clear).removedEntries, 0);
    final moved = Directory(p.join(sandbox.path, 'moved'));
    await cache.root.rename(moved.path);
    await Link(cache.root.path).create(moved.path);
    await expectLater(cache.clearUnpinned(), throwsStateError);
    expect(await File(p.join(moved.path, entry.fileName)).length(), 9);
  }, skip: Platform.isWindows ? 'Symlink privilege required' : false);

  test(
    'index write failure does not fabricate a successful cleanup result',
    () async {
      await store('one', 9);
      final indexTemp = Directory(p.join(cache.root.path, 'index.json.tmp'));
      await indexTemp.create();
      await expectLater(
        cache.clearUnpinned(),
        throwsA(isA<FileSystemException>()),
      );
      expect((await cache.measureUsage()).copies, 0);
      await indexTemp.delete();
      expect((await cache.clearUnpinned()).removedEntries, 0);
    },
  );
}
