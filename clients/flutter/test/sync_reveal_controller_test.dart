import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late SyncController controller;
  late SyncFolderConfig folder;

  setUp(() async {
    final temp = await Directory.systemTemp.createTemp('controller-reveal-');
    root = Directory(await temp.resolveSymbolicLinks());
    folder = SyncFolderConfig(
        id: 'folder',
        name: 'Local',
        localPath: root.path,
        remoteRootId: 'opaque');
    controller = SyncController(
        server: 'http://127.0.0.1:1',
        token: 'unused',
        handle: 0,
        api: ApiClient(baseUrl: 'http://127.0.0.1:1'),
        syncRunner: (_, __, ___) async => throw StateError('No sync allowed'),
        inspectRunner: (_, __) async => throw StateError('No HTTP allowed'));
    controller.folders.add(folder);
    await File(p.join(root.path, 'file')).writeAsString('local');
  });
  tearDown(() async {
    await controller.stopAndDrain();
    controller.dispose();
    await root.delete(recursive: true);
  });

  test('controller reveals local-only bytes without native keys or sync',
      () async {
    expect(await controller.canRevealLocal(folder, 'file', isDirectory: false),
        isTrue);
    final calls = <List<String>>[];
    await controller.revealLocal(folder, 'file', isDirectory: false,
        launch: (_, args) async {
      calls.add(args);
      return ProcessResult(0, 0, '', '');
    });
    expect(calls, [
      [root.path]
    ]);
    expect(folder.lastReport, isNull);
    expect(folder.lastSync, isNull);
  });

  test('removed folders and stopped sessions reject late reveal', () async {
    var launched = false;
    Future<ProcessResult> launch(String _, List<String> __) async {
      launched = true;
      return ProcessResult(0, 0, '', '');
    }

    controller.folders.clear();
    expect(await controller.canRevealLocal(folder, 'file', isDirectory: false),
        isFalse);
    await expectLater(
        controller.revealLocal(folder, 'file',
            isDirectory: false, launch: launch),
        throwsStateError);
    controller.folders.add(folder);
    await controller.stopAndDrain();
    expect(await controller.canRevealLocal(folder, 'file', isDirectory: false),
        isFalse);
    await expectLater(
        controller.revealLocal(folder, 'file',
            isDirectory: false, launch: launch),
        throwsStateError);
    expect(launched, isFalse);
  });

  test('removal or shutdown during revalidation cannot launch', () async {
    for (final stop in [false, true]) {
      final reveal = controller.revealLocal(folder, 'file',
          isDirectory: false, launch: (_, __) async => fail('Late launch'));
      // The first real filesystem await suspends inspection.
      if (stop) {
        final drain = controller.stopAndDrain();
        await expectLater(reveal, throwsStateError);
        await drain;
      } else {
        controller.folders.clear();
        await expectLater(reveal, throwsStateError);
        controller.folders.add(folder);
      }
    }
  });

  test('drain awaits an admitted launcher before finishing', () async {
    final started = Completer<void>();
    final finish = Completer<ProcessResult>();
    final reveal = controller.revealLocal(folder, 'file', isDirectory: false,
        launch: (_, __) {
      started.complete();
      return finish.future;
    });
    await started.future;
    var drained = false;
    final drain = controller.stopAndDrain().then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    finish.complete(ProcessResult(0, 0, '', ''));
    await reveal;
    await drain;
    expect(drained, isTrue);
  });
}
