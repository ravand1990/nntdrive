import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory cacheRoot;
  late DateTime now;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('nntdrive-cache-test');
    cacheRoot = Directory(p.join(sandbox.path, 'download-cache'));
    now = DateTime.utc(2026, 11, 22, 9);
  });

  tearDown(() async {
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  DownloadCache newCache({int limitBytes = 1024 * 1024}) =>
      DownloadCache(root: cacheRoot, limitBytes: limitBytes, clock: () => now);

  Future<File> sourceFile(String name, int bytes) async {
    final file = File(p.join(sandbox.path, name));
    await file.writeAsBytes(List<int>.filled(bytes, 7));
    return file;
  }

  Future<DownloadCache> openCache({int limitBytes = 1024 * 1024}) async {
    final cache = newCache(limitBytes: limitBytes);
    await cache.open();
    return cache;
  }

  group('storing and reopening', () {
    test('a stored revision is a copy with the recorded size', () async {
      final cache = await openCache();
      final source = await sourceFile('source.bin', 128);
      final entry = await cache.store(
        fileId: 'file-a',
        revisionId: 'rev-1',
        source: source,
        pinned: true,
      );

      expect(entry.sizeBytes, 128);
      expect(cache.usage.usedBytes, 128);
      expect(cache.usage.pinnedBytes, 128);
      expect(
        await source.exists(),
        isTrue,
        reason: 'the caller keeps its file',
      );
      expect(await cache.localFile('file-a', 'rev-1')!.length(), 128);
    });

    test('pinned copies survive a restart and stay pinned', () async {
      final first = await openCache();
      final source = await sourceFile('source.bin', 64);
      await first.store(
        fileId: 'file-a',
        revisionId: 'rev-1',
        source: source,
        pinned: true,
      );

      final reopened = await openCache();
      final entry = reopened.find('file-a', revisionId: 'rev-1');
      expect(entry, isNotNull);
      expect(entry!.pinned, isTrue);
      expect(reopened.localFile('file-a', 'rev-1'), isNotNull);
    });

    test('a changed revision is a separate entry, not an overwrite', () async {
      final cache = await openCache();
      final one = await sourceFile('one.bin', 10);
      final two = await sourceFile('two.bin', 20);
      await cache.store(fileId: 'file-a', revisionId: 'rev-1', source: one);
      await cache.store(fileId: 'file-a', revisionId: 'rev-2', source: two);

      expect(cache.find('file-a', revisionId: 'rev-1')!.sizeBytes, 10);
      expect(cache.find('file-a', revisionId: 'rev-2')!.sizeBytes, 20);
      expect(cache.entryCount, 2);
    });
  });

  group('bounded cache and eviction', () {
    test(
      'the oldest unpinned copy is evicted when the limit is exceeded',
      () async {
        final cache = await openCache(limitBytes: 200);
        for (final (id, revision, size) in [
          ('file-old', 'rev-1', 100),
          ('file-new', 'rev-1', 100),
          ('file-newest', 'rev-1', 100),
        ]) {
          final source = await sourceFile('$id.bin', size);
          await cache.store(fileId: id, revisionId: revision, source: source);
          now = now.add(const Duration(minutes: 1));
        }

        expect(cache.entryCount, 2);
        expect(
          cache.find('file-old'),
          isNull,
          reason: 'least recently used went first',
        );
        expect(cache.find('file-new'), isNotNull);
        expect(cache.find('file-newest'), isNotNull);
        expect(cache.usage.usedBytes, lessThanOrEqualTo(200));
      },
    );

    test(
      'a pinned copy is never evicted, even when it is the oldest',
      () async {
        final cache = await openCache(limitBytes: 150);
        final pinnedSource = await sourceFile('pinned.bin', 100);
        await cache.store(
          fileId: 'file-pinned',
          revisionId: 'rev-1',
          source: pinnedSource,
          pinned: true,
        );
        now = now.add(const Duration(minutes: 1));
        final firstScratch = await sourceFile('scratch-1.bin', 100);
        await cache.store(
          fileId: 'file-1',
          revisionId: 'rev-1',
          source: firstScratch,
        );
        now = now.add(const Duration(minutes: 1));
        final secondScratch = await sourceFile('scratch-2.bin', 100);
        await cache.store(
          fileId: 'file-2',
          revisionId: 'rev-1',
          source: secondScratch,
        );

        expect(cache.find('file-pinned', revisionId: 'rev-1'), isNotNull);
        expect(cache.localFile('file-pinned', 'rev-1'), isNotNull);
        expect(
          cache.find('file-1'),
          isNull,
          reason: 'the oldest unpinned copy went',
        );
        expect(
          cache.find('file-2'),
          isNotNull,
          reason: 'the copy just stored is protected from its own store pass',
        );
        // The pin plus the newest scratch copy is above the limit on its own.
        // That is the documented exception: only pinned or newly stored bytes
        // remain, and neither may be deleted to satisfy the limit.
        expect(cache.usage.usedBytes, 200);
        expect(cache.usage.pinnedBytes, 100);

        now = now.add(const Duration(minutes: 1));
        final thirdScratch = await sourceFile('scratch-3.bin', 100);
        await cache.store(
          fileId: 'file-3',
          revisionId: 'rev-1',
          source: thirdScratch,
        );
        expect(
          cache.find('file-2'),
          isNull,
          reason: 'the next store evicts it once it is no longer protected',
        );
        expect(cache.find('file-pinned', revisionId: 'rev-1'), isNotNull);
        expect(cache.find('file-3'), isNotNull);
      },
    );

    test(
      'touching a copy moves it to the front of the eviction order',
      () async {
        final cache = await openCache(limitBytes: 250);
        final first = await sourceFile('first.bin', 100);
        await cache.store(fileId: 'file-1', revisionId: 'rev-1', source: first);
        now = now.add(const Duration(minutes: 1));
        final second = await sourceFile('second.bin', 100);
        await cache.store(
          fileId: 'file-2',
          revisionId: 'rev-1',
          source: second,
        );

        now = now.add(const Duration(minutes: 1));
        await cache.touch('file-1', 'rev-1');
        final third = await sourceFile('third.bin', 100);
        await cache.store(fileId: 'file-3', revisionId: 'rev-1', source: third);

        expect(
          cache.find('file-2'),
          isNull,
          reason: 'now the least recently used',
        );
        expect(cache.find('file-1'), isNotNull);
        expect(cache.find('file-3'), isNotNull);
      },
    );

    test(
      'unpinning makes the copy evictable and runs the limit at once',
      () async {
        final cache = await openCache(limitBytes: 150);
        final pinnedSource = await sourceFile('pinned.bin', 100);
        await cache.store(
          fileId: 'file-pinned',
          revisionId: 'rev-1',
          source: pinnedSource,
          pinned: true,
        );
        now = now.add(const Duration(minutes: 1));
        final scratch = await sourceFile('scratch.bin', 100);
        await cache.store(
          fileId: 'file-scratch',
          revisionId: 'rev-1',
          source: scratch,
        );
        expect(cache.usage.usedBytes, 200);

        await cache.setPinned('file-pinned', 'rev-1', false);
        expect(cache.usage.pinnedBytes, 0);
        // Both copies are now evictable, so the oldest goes and the cache fits.
        expect(cache.find('file-pinned', revisionId: 'rev-1'), isNull);
        expect(cache.usage.usedBytes, lessThanOrEqualTo(150));
      },
    );
  });

  group('cleanup reports what it reclaimed', () {
    test(
      'clearUnpinned removes only unpinned copies and counts bytes',
      () async {
        final cache = await openCache();
        final pinned = await sourceFile('pinned.bin', 300);
        await cache.store(
          fileId: 'file-pinned',
          revisionId: 'rev-1',
          source: pinned,
          pinned: true,
        );
        final scratch = await sourceFile('scratch.bin', 200);
        await cache.store(
          fileId: 'file-scratch',
          revisionId: 'rev-1',
          source: scratch,
        );

        final cleanup = await cache.clearUnpinned();

        expect(cleanup.removedEntries, 1);
        expect(cleanup.freedBytes, 200);
        expect(cleanup.keptPinnedEntries, 1);
        expect(cache.find('file-scratch'), isNull);
        expect(cache.find('file-pinned', revisionId: 'rev-1'), isNotNull);
        expect(cache.usage.usedBytes, 300);
      },
    );

    test(
      'removing a pinned copy is only possible on an explicit request',
      () async {
        final cache = await openCache();
        final source = await sourceFile('pinned.bin', 32);
        await cache.store(
          fileId: 'file-pinned',
          revisionId: 'rev-1',
          source: source,
          pinned: true,
        );

        expect(
          await cache.remove('file-pinned', 'rev-1', evenIfPinned: false),
          isFalse,
        );
        expect(cache.find('file-pinned', revisionId: 'rev-1'), isNotNull);
        expect(await cache.remove('file-pinned', 'rev-1'), isTrue);
        expect(cache.find('file-pinned'), isNull);
        expect(cache.usage.usedBytes, 0);
      },
    );
  });

  group('the cache stays inside its own directory', () {
    test('a tampered index cannot point at a file outside the root', () async {
      final outsider = await sourceFile('keeper.txt', 12);
      await cacheRoot.create(recursive: true);
      await File(p.join(cacheRoot.path, 'index.json')).writeAsString(
        jsonEncode({
          'version': 1,
          'entries': [
            {
              'fileId': 'file-a',
              'revisionId': 'rev-1',
              'fileName': '../keeper.txt',
              'sizeBytes': 12,
              'storedAt': now.toIso8601String(),
              'lastUsedAt': now.toIso8601String(),
              'pinned': false,
            },
            {
              'fileId': 'file-b',
              'revisionId': 'rev-1',
              'fileName': '${'a' * 32}.bin',
              'sizeBytes': 4,
              'storedAt': now.toIso8601String(),
              'lastUsedAt': now.toIso8601String(),
              'pinned': true,
            },
          ],
        }),
      );

      final cache = await openCache();
      expect(cache.find('file-a'), isNull);
      expect(
        cache.entryCount,
        0,
        reason: 'the listed file does not exist either',
      );
      expect(await outsider.exists(), isTrue);
      expect(await outsider.length(), 12);

      await cache.clearUnpinned();
      await cache.enforceLimit();
      expect(await outsider.exists(), isTrue);
    });

    test('eviction and cleanup never touch a neighbouring directory', () async {
      final documents = Directory(p.join(sandbox.path, 'documents'));
      await documents.create();
      final saved = File(p.join(documents.path, 'report.pdf'));
      await saved.writeAsBytes(List<int>.filled(10, 1));
      final cache = await openCache(limitBytes: 50);
      final source = await sourceFile('scratch.bin', 100);
      await cache.store(fileId: 'file-a', revisionId: 'rev-1', source: source);
      // A source that was never adopted also lives beside the cache, not in it.
      final loose = await sourceFile('loose.bin', 40);

      await cache.clearUnpinned();
      await cache.enforceLimit();

      expect(await saved.exists(), isTrue);
      expect(await loose.exists(), isTrue);
      expect(await saved.length(), 10);
    });

    test(
      'adopting refuses a file that is not directly inside the cache',
      () async {
        final cache = await openCache();
        final outside = await sourceFile('outside.bin', 8);
        await expectLater(
          cache.adopt(fileId: 'file-a', revisionId: 'rev-1', source: outside),
          throwsArgumentError,
        );
        expect(await outside.exists(), isTrue);
        expect(cache.entryCount, 0);
      },
    );

    test(
      'a cache file replaced by a link is dropped without touching its target',
      () async {
        final cache = await openCache();
        final source = await sourceFile('source.bin', 16);
        await cache.store(
          fileId: 'file-a',
          revisionId: 'rev-1',
          source: source,
          pinned: true,
        );
        final outside = await sourceFile('target.bin', 16);
        final cachedPath = cache.localFile('file-a', 'rev-1')!.path;

        try {
          await File(cachedPath).delete();
          await Link(cachedPath).create(outside.path);
        } on FileSystemException {
          // Link creation can be unavailable to an unprivileged Windows account;
          // the Unix and container runs of this test do exercise it.
          return;
        }

        final reopened = await openCache();
        expect(reopened.find('file-a'), isNull);
        expect(
          await outside.exists(),
          isTrue,
          reason: 'the link target is untouched',
        );
        expect(await outside.length(), 16);
      },
    );

    test('an interrupted download leaves no committed entry', () async {
      await cacheRoot.create(recursive: true);
      final partial = File(p.join(cacheRoot.path, 'aaaa.part'));
      await partial.writeAsBytes([1, 2, 3]);

      final cache = await openCache();
      expect(await partial.exists(), isFalse);
      expect(cache.entryCount, 0);
    });

    test('a corrupt index is reported and its bytes are not deleted', () async {
      await cacheRoot.create(recursive: true);
      final kept = File(p.join(cacheRoot.path, '${'b' * 32}.bin'));
      await kept.writeAsBytes([1, 2, 3, 4]);
      await File(
        p.join(cacheRoot.path, 'index.json'),
      ).writeAsString('{not json');

      final cache = newCache();
      final report = await cache.open();

      expect(report.recoveredCorruptIndex, isTrue);
      expect(cache.entryCount, 0);
      expect(
        await kept.exists(),
        isTrue,
        reason: 'without the index the file could be pinned, so it stays',
      );
    });

    test(
      'an orphaned cache file is removed after a clean index read',
      () async {
        await cacheRoot.create(recursive: true);
        final orphan = File(p.join(cacheRoot.path, '${'c' * 32}.bin'));
        await orphan.writeAsBytes([1, 2, 3]);

        final cache = newCache();
        final report = await cache.open();

        expect(report.removedOrphanFiles, 1);
        expect(await orphan.exists(), isFalse);
      },
    );
  });

  group('file naming', () {
    test('derived from opaque IDs, so a name never comes from a listing', () {
      final one = DownloadCache.fileNameFor('file-a', 'rev-1');
      final two = DownloadCache.fileNameFor('file-a', 'rev-2');
      expect(one, matches(RegExp(r'^[0-9a-f]{32}\.bin$')));
      expect(one, isNot(two));
      expect(DownloadCache.fileNameFor('file-a', 'rev-1'), one);
    });

    test('usage reports pinned and used bytes separately', () async {
      final cache = await openCache(limitBytes: 1000);
      final pinned = await sourceFile('pinned.bin', 300);
      await cache.store(
        fileId: 'file-pinned',
        revisionId: 'rev-1',
        source: pinned,
        pinned: true,
      );
      final scratch = await sourceFile('scratch.bin', 200);
      await cache.store(
        fileId: 'file-scratch',
        revisionId: 'rev-1',
        source: scratch,
      );

      expect(cache.usage.limitBytes, 1000);
      expect(cache.usage.usedBytes, 500);
      expect(cache.usage.pinnedBytes, 300);
      expect(cache.usage.headroomBytes, 500);
    });
  });

  group('changing the limit', () {
    for (final adopt in [false, true]) {
      test(
        'shrink protects the just-${adopt ? 'adopted' : 'stored'} revision',
        () async {
          final cache = await openCache(limitBytes: 1000);
          final older = await sourceFile('older.bin', 200);
          await cache.store(fileId: 'older', revisionId: 'r1', source: older);
          now = now.add(const Duration(minutes: 1));
          final source = adopt
              ? File(p.join(cache.root.path, 'download.part'))
              : await sourceFile('latest.bin', 600);
          if (adopt) await source.writeAsBytes(List<int>.filled(600, 7));
          final latest = adopt
              ? await cache.adopt(
                  fileId: 'latest',
                  revisionId: 'r1',
                  source: source,
                )
              : await cache.store(
                  fileId: 'latest',
                  revisionId: 'r1',
                  source: source,
                );

          final cleanup = await cache.setLimit(100);
          expect(cleanup.removedEntries, 1);
          expect(cache.find('older'), isNull);
          expect(cache.find('latest'), isNotNull);
          expect(await cache.fileFor(latest).length(), 600);
          expect(cache.usage.usedBytes, 600);
          expect(cache.usage.headroomBytes, 0);

          // The protection moves to the next completed store, not a permanent pin.
          final next = await sourceFile('next.bin', 50);
          await cache.store(fileId: 'next', revisionId: 'r1', source: next);
          expect(cache.find('latest'), isNull);
          expect(cache.find('next'), isNotNull);
          expect(cache.usage.usedBytes, 50);
          await cache.clearUnpinned();
          expect(
            cache.entryCount,
            0,
            reason: 'explicit cleanup is still allowed',
          );
        },
      );
    }
    test('shrinking evicts the oldest unpinned copy and persists', () async {
      final cache = await openCache(limitBytes: 1000);
      final pinned = await sourceFile('pinned.bin', 100);
      await cache.store(
        fileId: 'file-pinned',
        revisionId: 'rev-1',
        source: pinned,
        pinned: true,
      );
      final older = await sourceFile('older.bin', 400);
      await cache.store(
        fileId: 'file-older',
        revisionId: 'rev-1',
        source: older,
      );
      now = now.add(const Duration(minutes: 1));
      final newer = await sourceFile('newer.bin', 400);
      await cache.store(
        fileId: 'file-newer',
        revisionId: 'rev-1',
        source: newer,
      );

      final cleanup = await cache.setLimit(600);

      expect(cleanup.removedEntries, 1);
      expect(cleanup.freedBytes, 400);
      expect(cache.limitBytes, 600);
      expect(cache.find('file-older'), isNull, reason: 'least recently used');
      expect(cache.find('file-pinned'), isNotNull);
      expect(cache.find('file-newer'), isNotNull);
      expect(cache.usage.usedBytes, 500);
      expect(cache.usage.headroomBytes, 100);

      // A restart sees the shrunk cache: the index was rewritten.
      final reopened = newCache(limitBytes: 600);
      await reopened.open();
      expect(reopened.find('file-older'), isNull);
      expect(reopened.usage.usedBytes, 500);
    });

    test(
      'a limit below the kept-offline total never deletes pinned copies',
      () async {
        final cache = await openCache(limitBytes: 1000);
        // The unpinned copy is older; the newest protected copy is pinned.
        final scratch = await sourceFile('scratch.bin', 200);
        await cache.store(
          fileId: 'file-scratch',
          revisionId: 'rev-1',
          source: scratch,
        );
        final pinned = await sourceFile('pinned.bin', 300);
        await cache.store(
          fileId: 'file-pinned',
          revisionId: 'rev-1',
          source: pinned,
          pinned: true,
        );

        final cleanup = await cache.setLimit(100);

        expect(cleanup.removedEntries, 1, reason: 'the unpinned copy goes');
        expect(cleanup.keptPinnedEntries, 1);
        expect(cache.find('file-pinned'), isNotNull);
        expect(cache.usage.pinnedBytes, 300);
        expect(
          cache.usage.usedBytes,
          300,
          reason: 'above the limit because pinned copies are kept',
        );
        expect(cache.usage.headroomBytes, 0);
      },
    );

    test('a non-positive limit is refused and changes nothing', () async {
      final cache = await openCache(limitBytes: 1000);
      final scratch = await sourceFile('scratch.bin', 200);
      await cache.store(
        fileId: 'file-scratch',
        revisionId: 'rev-1',
        source: scratch,
      );

      await expectLater(cache.setLimit(0), throwsArgumentError);
      expect(cache.limitBytes, 1000);
      expect(cache.entryCount, 1);
    });

    test('raising the limit keeps every existing copy', () async {
      final cache = await openCache(limitBytes: 1000);
      final scratch = await sourceFile('scratch.bin', 400);
      await cache.store(
        fileId: 'file-scratch',
        revisionId: 'rev-1',
        source: scratch,
      );

      final cleanup = await cache.setLimit(4096);

      expect(cleanup.removedEntries, 0);
      expect(cache.usage.usedBytes, 400);
      expect(cache.usage.headroomBytes, 3696);
    });
  });
}
