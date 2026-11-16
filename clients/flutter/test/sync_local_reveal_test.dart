import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_local_reveal.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory root;
  late SyncFolderConfig folder;
  final desktop = Platform.isLinux || Platform.isMacOS || Platform.isWindows;
  final linkSkip = Platform.isWindows
      ? 'Requires symlink permission; installed Windows acceptance remains.'
      : false;

  setUp(() async {
    final temporary =
        await Directory.systemTemp.createTemp('sync-local-reveal-');
    // macOS system temp paths may themselves contain a symlink.
    sandbox = Directory(await temporary.resolveSymbolicLinks());
    root = await Directory(p.join(sandbox.path, 'root')).create();
    folder = SyncFolderConfig(
        id: 'config',
        name: 'Private folder name',
        localPath: root.path,
        remoteRootId: 'opaque-root');
  });

  tearDown(() async => sandbox.delete(recursive: true));

  Future<LocalAvailability> inspect(String path, {bool directory = false}) =>
      inspectSyncLocalPath(
          folder: folder, relativePath: path, isDirectory: directory);

  test('files, nested folders and the root retain exact local identity',
      () async {
    final nested = await Directory(p.join(root.path, 'nested')).create();
    final file =
        await File(p.join(nested.path, 'a.txt')).writeAsString('local');
    final state = await inspect('nested/a.txt');
    expect(state.path, file.path);
    expect(state.folder, same(folder));
    expect(state.relativePath, 'nested/a.txt');
    expect(state.isDirectory, isFalse);
    expect(state.verifiedAtRefresh, isFalse);
    expect(state.explanation, contains('not verified'));
    final directory = await inspect('nested', directory: true);
    expect(directory.path, nested.path);
    expect(directory.isDirectory, isTrue);
    final rootState = await inspect('', directory: true);
    expect(rootState.path, root.path);
    expect(rootState.relativePath, '');
    expect(rootState.isDirectory, isTrue);
    expect((await inspect('')).path, isNull);
  });

  test('excluded and disabled local items remain revealable without syncing',
      () async {
    final nested = await Directory(p.join(root.path, 'excluded')).create();
    final file =
        await File(p.join(nested.path, 'a.txt')).writeAsString('local');
    folder.excluded = ['excluded'];
    folder.enabled = false;
    expect((await inspect('excluded/a.txt')).path, file.path);
    expect((await inspect('excluded', directory: true)).path, nested.path);
    expect(folder.excluded, ['excluded']);
    expect(folder.enabled, isFalse);
    expect(folder.running, isFalse);
    expect(folder.lastReport, isNull);
  });

  test('missing paths and wrong types have no reveal target', () async {
    expect((await inspect('missing')).path, isNull);
    expect((await inspect('missing/child')).path, isNull);
    expect((await inspect('missing', directory: true)).path, isNull);
    await File(p.join(root.path, 'file')).writeAsString('local');
    await Directory(p.join(root.path, 'directory')).create();
    expect((await inspect('file', directory: true)).path, isNull);
    expect((await inspect('file/child')).path, isNull);
    expect((await inspect('directory')).path, isNull);
    await root.delete(recursive: true);
    expect((await inspect('', directory: true)).path, isNull);
    await File(root.path).writeAsString('not a directory');
    expect((await inspect('', directory: true)).path, isNull);
    folder.localPath = '';
    expect((await inspect('', directory: true)).path, isNull);
  });

  test(
      'absolute, traversal and nonportable components fail without normalization',
      () async {
    await File(p.join(sandbox.path, 'outside')).writeAsString('private');
    await File(p.join(root.path, 'safe')).writeAsString('local');
    final invalid = [
      '/outside',
      p.join(sandbox.path, 'outside'),
      r'C:\outside',
      'C:/outside',
      'C:outside',
      r'\\server\share',
      r'folder\file',
      '.',
      '..',
      '../outside',
      'safe/../safe',
      'safe/./child',
      '/safe',
      'safe/',
      'safe//child',
      'NUL.txt',
      'COM¹.txt',
      'trailing.',
      ' leading',
      'trailing ',
      'bad:component',
      'bad\u0000name',
      String.fromCharCode(0xd800),
    ];
    for (final path in invalid) {
      expect((await inspect(path)).path, isNull);
      expect((await inspect(path, directory: true)).path, isNull);
    }
  });

  test('public diagnostics never include private paths or raw reports',
      () async {
    folder.lastError = 'PRIVATE ERROR';
    folder.lastReport = {
      'item_errors': [
        {
          'paths': ['missing'],
          'operation': 'upload',
          'code': 'io',
          'message': 'PRIVATE ERROR'
        }
      ]
    };
    final states = [
      await inspect('missing'),
      await inspect('../PRIVATE NAME'),
      await inspect('', directory: true),
    ];
    for (final state in states) {
      final diagnostic = '${state.label} ${state.explanation} '
          '${state.displayLabel} ${state.displayExplanation}';
      expect(diagnostic, isNot(contains(sandbox.path)));
      expect(diagnostic, isNot(contains('PRIVATE')));
      expect(diagnostic, isNot(contains(folder.name)));
    }
  });

  test('linked file, directory and intermediate component fail closed',
      () async {
    final outside = await Directory(p.join(sandbox.path, 'outside')).create();
    final file =
        await File(p.join(outside.path, 'a.txt')).writeAsString('private');
    await Link(p.join(root.path, 'file-link')).create(file.path);
    await Link(p.join(root.path, 'directory-link')).create(outside.path);
    expect((await inspect('file-link')).path, isNull);
    expect((await inspect('directory-link', directory: true)).path, isNull);
    expect((await inspect('directory-link/a.txt')).path, isNull);
    await Link(p.join(root.path, 'broken'))
        .create(p.join(outside.path, 'missing'));
    expect((await inspect('broken')).path, isNull);
    // Even a link staying inside the configured root is not accepted.
    final inside =
        await File(p.join(root.path, 'inside')).writeAsString('local');
    await Link(p.join(root.path, 'inside-link')).create(inside.path);
    expect((await inspect('inside-link')).path, isNull);
  }, skip: linkSkip);

  test('linked root and root ancestor fail closed', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    final alias =
        await Link(p.join(sandbox.path, 'root-alias')).create(root.path);
    folder.localPath = alias.path;
    expect((await inspect('a.txt')).path, isNull);
    expect((await inspect('', directory: true)).path, isNull);
    final parentAlias =
        await Link(p.join(sandbox.path, 'parent-alias')).create(sandbox.path);
    folder.localPath = p.join(parentAlias.path, 'root');
    expect((await inspect('a.txt')).path, isNull);
    expect((await inspect('', directory: true)).path, isNull);
  }, skip: linkSkip);

  test('launcher opens file parent, directory itself and root itself',
      () async {
    final nested = await Directory(p.join(root.path, 'nested')).create();
    await File(p.join(nested.path, 'a.txt')).writeAsString('local');
    final launches = <List<String>>[];
    Future<ProcessResult> launch(String command, List<String> arguments) async {
      expect(
          command,
          Platform.isWindows
              ? 'explorer.exe'
              : Platform.isMacOS
                  ? 'open'
                  : 'xdg-open');
      launches.add(arguments);
      return ProcessResult(0, 0, '', '');
    }

    await revealLocalAvailability(() => inspect('nested/a.txt'),
        launch: launch);
    await revealLocalAvailability(() => inspect('nested', directory: true),
        launch: launch);
    await revealLocalAvailability(() => inspect('', directory: true),
        launch: launch);
    expect(launches, [
      [nested.path],
      [nested.path],
      [root.path]
    ]);
  }, skip: !desktop);

  test('reveal revalidates deleted and wrong-type stale targets before launch',
      () async {
    final file = await File(p.join(root.path, 'a.txt')).writeAsString('local');
    expect((await inspect('a.txt')).path, file.path);
    var calls = 0;
    Future<ProcessResult> launch(String command, List<String> arguments) async {
      calls++;
      return ProcessResult(0, 0, '', '');
    }

    await file.delete();
    await expectLater(
        revealLocalAvailability(() => inspect('a.txt'), launch: launch),
        throwsStateError);
    await Directory(file.path).create();
    await expectLater(
        revealLocalAvailability(() => inspect('a.txt'), launch: launch),
        throwsStateError);
    expect(calls, 0);
  }, skip: !desktop);

  test('reveal revalidates stale link replacements before launch', () async {
    final file = await File(p.join(root.path, 'a.txt')).writeAsString('local');
    expect((await inspect('a.txt')).path, file.path);
    await file.delete();
    final outside =
        await File(p.join(sandbox.path, 'outside')).writeAsString('private');
    await Link(file.path).create(outside.path);
    var launched = false;
    await expectLater(
        revealLocalAvailability(() => inspect('a.txt'),
            launch: (command, arguments) async {
          launched = true;
          return ProcessResult(0, 0, '', '');
        }),
        throwsStateError);
    expect(launched, isFalse);
  }, skip: !desktop ? true : linkSkip);

  test('launcher failure exposes only a fixed diagnostic', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    await expectLater(
        revealLocalAvailability(() => inspect('a.txt'),
            launch: (command, arguments) async =>
                ProcessResult(0, 1, 'PRIVATE STDOUT', 'PRIVATE STDERR')),
        throwsA(isA<StateError>().having((error) => error.message, 'message',
            'Could not open file manager.')));
  }, skip: !desktop);
}
