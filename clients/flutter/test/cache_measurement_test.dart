import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late DownloadCache cache;
  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('cache-measurement');
    cache = DownloadCache(root: Directory(p.join(sandbox.path, 'cache')));
    await cache.open();
  });
  tearDown(() async => sandbox.delete(recursive: true));

  Future<CachedDownload> store(
    String revision,
    int bytes, {
    bool pin = false,
  }) async {
    final source = File(p.join(sandbox.path, 'source'));
    await source.writeAsBytes(List.filled(bytes, 7));
    return cache.store(
      fileId: 'opaque',
      revisionId: revision,
      source: source,
      pinned: pin,
    );
  }

  test(
    'measures real lengths, revision counts, pin changes and restart',
    () async {
      final pinned = await store('one', 9, pin: true);
      await store('two', 0);
      await store('three', 4);
      cache = DownloadCache(root: cache.root);
      await cache.open();
      var result = await cache.measureUsage();
      expect((result.bytes, result.copies), (13, 3));
      expect((result.pinnedBytes, result.pinnedCopies), (9, 1));
      expect((result.unpinnedBytes, result.unpinnedCopies), (4, 2));
      await cache.setPinned('opaque', 'one', false);
      await cache.fileFor(pinned).writeAsBytes(List.filled(17, 8));
      result = await cache.measureUsage();
      expect(
        cache.usage.usedBytes,
        13,
        reason: 'old index sizes are not measurement',
      );
      expect((result.bytes, result.copies), (21, 3));
      expect((result.pinnedBytes, result.pinnedCopies), (0, 0));
    },
  );

  test(
    'missing, linked and replaced entries excluded without cleanup or writes',
    () async {
      final gone = await store('gone', 3, pin: true);
      final linked = await store('linked', 5, pin: true);
      final directory = await store('directory', 8);
      await store('kept', 2);
      await cache.fileFor(gone).delete();
      await cache.fileFor(linked).delete();
      final outside = File(p.join(sandbox.path, 'outside'));
      await outside.writeAsBytes(List.filled(100, 1));
      await Link(cache.fileFor(linked).path).create(outside.path);
      await cache.fileFor(directory).delete();
      await Directory(cache.fileFor(directory).path).create();
      final scratch = File(p.join(cache.root.path, 'leftover.part'));
      final orphan = File(p.join(cache.root.path, '${'a' * 32}.bin'));
      await scratch.writeAsString('scratch');
      await orphan.writeAsString('orphan');
      final index = File(p.join(cache.root.path, 'index.json'));
      final before = await index.readAsString();
      final result = await cache.measureUsage();
      expect((result.bytes, result.copies, result.excludedCopies), (2, 1, 3));
      expect((result.pinnedBytes, result.pinnedCopies), (0, 0));
      expect(await index.readAsString(), before);
      expect(cache.entryCount, 4);
      expect(await scratch.readAsString(), 'scratch');
      expect(await orphan.readAsString(), 'orphan');
      expect(await outside.length(), 100);
      expect(await Link(cache.fileFor(linked).path).exists(), isTrue);
    },
    skip: Platform.isWindows ? 'Symlink privilege required' : false,
  );

  test(
    'closed, missing root and corrupt index are unavailable, not zero',
    () async {
      final unopened = DownloadCache(root: cache.root);
      await expectLater(unopened.measureUsage(), throwsStateError);
      await cache.root.delete(recursive: true);
      await expectLater(cache.measureUsage(), throwsStateError);
      await cache.root.create();
      await File(
        p.join(cache.root.path, 'index.json'),
      ).writeAsString('{broken');
      await cache.open();
      await expectLater(cache.measureUsage(), throwsStateError);
    },
  );

  test('root and ancestor directory links fail closed', () async {
    await store('one', 9);
    final original = cache.root;
    final moved = Directory(p.join(sandbox.path, 'moved'));
    await original.rename(moved.path);
    await Link(original.path).create(moved.path);
    await expectLater(cache.measureUsage(), throwsStateError);
    await Link(original.path).delete();
    await moved.rename(original.path);
    final oldSandbox = sandbox.path;
    final movedSandbox = '$oldSandbox-moved';
    await sandbox.rename(movedSandbox);
    try {
      await Link(oldSandbox).create(movedSandbox);
      await expectLater(cache.measureUsage(), throwsStateError);
    } finally {
      await Link(oldSandbox).delete();
      await Directory(movedSandbox).rename(oldSandbox);
    }
  }, skip: Platform.isWindows ? 'Symlink privilege required' : false);

  test('measurement serializes behind admitted pin writes', () async {
    await store('one', 9);
    final pin = cache.setPinned('opaque', 'one', true);
    final measured = cache.measureUsage();
    await pin;
    final result = await measured;
    expect((result.pinnedBytes, result.pinnedCopies), (9, 1));
    await cache.remove('opaque', 'one');
    expect((await cache.measureUsage()).copies, 0);
  });
}
