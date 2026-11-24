import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'completed sync and conflict resolution invalidate once, never byte progress or failure',
    () async {
      final scratch = await Directory.systemTemp.createTemp('sync-mutation-');
      SharedPreferences.setMockInitialValues({});
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => scratch.path,
      );
      var changes = 0;
      var fail = false;
      final entered = Completer<void>();
      final release = Completer<void>();
      final api = ApiClient(baseUrl: 'http://unused')
        ..onAccountChanged = () => changes++;
      final controller = SyncController(
        server: 'http://unused',
        token: '',
        handle: 0,
        api: api,
        syncRunner: (_, request, progress) async {
          for (var i = 0; i < 100; i++) {
            progress({
              'path': 'private.txt',
              'direction': 'upload',
              'bytes': i,
              'total': 100,
              'complete': i == 99,
            });
          }
          if (!entered.isCompleted) entered.complete();
          await release.future;
          if (fail) throw StateError('fixture failure');
          return {
            'uploaded': 1,
            'downloaded': 0,
            'conflicts': 0,
            'errors': [
              ['other.txt', 'partial failure'],
            ],
          };
        },
      );
      final folder = SyncFolderConfig(
        id: 'fixture',
        name: 'fixture',
        localPath: scratch.path,
        remoteRootId: 'opaque',
      );
      controller.folders.add(folder);
      try {
        final syncing = controller.syncFolder(folder);
        await entered.future;
        await Future<void>.delayed(Duration.zero);
        expect(
          changes,
          0,
          reason: 'Even complete per-file progress is not a finished run',
        );
        release.complete();
        expect(await syncing, isNotNull);
        expect(
          changes,
          1,
          reason: 'Partial completed reports can contain committed changes',
        );
        fail = true;
        expect(await controller.syncFolder(folder), isNull);
        expect(changes, 1);
        fail = false;
        await controller.resolveConflict(
          folder,
          'private (conflict Device 123).txt',
          'both',
        );
        expect(changes, 2);
        fail = true;
        await expectLater(
          controller.resolveConflict(
            folder,
            'private (conflict Device 123).txt',
            'both',
          ),
          throwsStateError,
        );
        expect(changes, 2);
        await controller.stopAndDrain();
        await controller.syncFolder(folder);
        expect(changes, 2);
      } finally {
        if (!release.isCompleted) release.complete();
        await controller.stopAndDrain();
        controller.dispose();
        messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
        await scratch.delete(recursive: true);
      }
    },
  );
}
