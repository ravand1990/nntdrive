import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/cache_duplicates.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:nntdrive/session_operations.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'real controller worker and session admission drain reject late results',
    () async {
      final temp = await Directory.systemTemp.createTemp('review-lifecycle');
      final dir = Directory(await temp.resolveSymbolicLinks());
      addTearDown(() => dir.delete(recursive: true));
      final cache = DownloadCache(root: Directory(p.join(dir.path, 'cache')));
      await cache.open();
      final source = File(p.join(dir.path, 'source'));
      await source.writeAsBytes([1, 2]);
      for (final id in ['a', 'b']) {
        await cache.store(fileId: id, revisionId: 'r', source: source);
      }
      final sync = SyncController(
        server: 'http://unused',
        token: '',
        handle: 0,
        api: ApiClient(baseUrl: 'http://unused'),
      );
      addTearDown(sync.dispose);
      expect((await sync.reviewCacheDuplicates(cache)).groups, hasLength(1));
      final operations = SessionOperations();
      final entered = Completer<void>();
      final release = Completer<void>();
      final pending = operations.run(
        1,
        () => sync.reviewCacheDuplicates(
          cache,
          runner: (root, entries, limits) async {
            entered.complete();
            await release.future;
            return runCacheDuplicateReview(root, entries, limits);
          },
        ),
      );
      await entered.future;
      final rejected = expectLater(pending, throwsStateError);
      var controllerDrained = false;
      var sessionDrained = false;
      final controllerDrain = sync.stopAndDrain().then(
        (_) => controllerDrained = true,
      );
      final sessionDrain = operations
          .drain(1)
          .then((_) => sessionDrained = true);
      await Future<void>.delayed(Duration.zero);
      expect(controllerDrained, false);
      expect(sessionDrained, false);
      await expectLater(sync.reviewCacheDuplicates(cache), throwsStateError);
      var admitted = false;
      await expectLater(
        operations.run(1, () async {
          admitted = true;
        }),
        throwsStateError,
      );
      expect(admitted, false);
      release.complete();
      await Future.wait([rejected, controllerDrain, sessionDrain]);
      expect(controllerDrained, true);
      expect(sessionDrained, true);
    },
  );
}
