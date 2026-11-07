import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/api.dart';

void main() {
  late Directory sandbox;
  late Directory root;
  late SyncFolderConfig folder;
  final ancestry = [(id: 'root', name: 'Remote'), (id: 'file', name: 'a.txt')];

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('availability-');
    root = await Directory(p.join(sandbox.path, 'root')).create();
    // Canonicalize the fixture itself (macOS temporary directories can be links).
    root = Directory(await root.resolveSymbolicLinks());
    folder = SyncFolderConfig(id: 'config', name: 'Root',
        localPath: root.path, remoteRootId: 'root');
  });
  tearDown(() async => sandbox.delete(recursive: true));

  Future<LocalAvailability> inspect({bool isDir = false}) =>
      inspectLocalAvailability(ancestry: ancestry, folders: [folder], isDir: isDir);

  test('presence is read again from disk, never last report', () async {
    folder.lastReport = {'downloaded': 1};
    expect((await inspect()).label, 'Cloud only');
    final file = await File(p.join(root.path, 'a.txt')).writeAsString('local');
    final local = await inspect();
    expect(local.label, 'Local');
    expect(local.path, file.path);
    expect(local.explanation, contains('content equality is not verified'));
    await file.delete();
    expect((await inspect()).label, 'Cloud only');
  });

  test('coverage uses node IDs, honors exclusions and rejects overlap', () async {
    expect((await inspectLocalAvailability(ancestry: ancestry,
        folders: [], isDir: false)).label, 'Not covered');
    folder.excluded = ['a.txt'];
    expect((await inspect()).label, 'Not covered');
    folder.excluded = [];
    expect((await inspectLocalAvailability(ancestry: ancestry,
        folders: [folder, folder], isDir: false)).label, 'Unknown');
  });

  test('missing root, wrong entity type and traversal fail closed', () async {
    await Directory(p.join(root.path, 'a.txt')).create();
    expect((await inspect()).label, 'Error');
    for (final bad in ['..', '../outside', r'..\outside', '/outside', 'NUL.txt']) {
      final state = await inspectLocalAvailability(
          ancestry: [(id: 'root', name: 'Remote'), (id: 'file', name: bad)],
          folders: [folder], isDir: false);
      expect(state.path, isNull, reason: bad);
      expect(state.label, 'Unknown');
    }
    await root.delete(recursive: true);
    expect((await inspect()).label, 'Error');
  });

  test('symlink files, directories and roots are never revealable', () async {
    final outside = await File(p.join(sandbox.path, 'outside')).writeAsString('secret');
    await Link(p.join(root.path, 'a.txt')).create(outside.path);
    expect((await inspect()).path, isNull);
    await Link(p.join(root.path, 'a.txt')).delete();
    await Link(p.join(root.path, 'nested')).create(sandbox.path);
    final nested = await inspectLocalAvailability(
        ancestry: [(id: 'root', name: 'Remote'),
          (id: 'dir', name: 'nested'), (id: 'file', name: 'outside')],
        folders: [folder], isDir: false);
    expect(nested.path, isNull);
    final alias = await Link(p.join(sandbox.path, 'alias')).create(root.path);
    folder.localPath = alias.path;
    expect((await inspect()).path, isNull);
  }, skip: Platform.isWindows ? 'Requires symlink permission; Windows manual acceptance remains.' : false);

  test('conflict presence and folder activity are labelled without completion claims', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('conflict');
    folder.conflictFiles = ['a.txt'];
    final state = await inspect();
    expect(state.displayLabel, 'Conflict');
    folder.running = true;
    expect(state.displayLabel, 'Syncing');
    expect(state.displayExplanation, contains('individual file completion is unknown'));
    folder.running = false;
    expect(state.displayLabel, 'Conflict');
  });

  test('reveal revalidates; deletion or link substitution never launches', () async {
    final file = await File(p.join(root.path, 'a.txt')).writeAsString('local');
    expect((await inspect()).path, isNotNull);
    await file.delete();
    var launched = false;
    Future<ProcessResult> launch(String command, List<String> args) async {
      launched = true;
      return ProcessResult(1, 0, '', '');
    }
    await expectLater(revealLocalAvailability(inspect, launch: launch), throwsStateError);
    expect(launched, isFalse);
    if (!Platform.isWindows) {
      final outside = await File(p.join(sandbox.path, 'replacement')).writeAsString('private');
      await Link(file.path).create(outside.path);
      await expectLater(revealLocalAvailability(inspect, launch: launch), throwsStateError);
      expect(launched, isFalse);
    }
  });

  test('reveal passes a single containing directory argument, not file contents or shell', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    await revealLocalAvailability(inspect, launch: (command, args) async {
      expect(command, Platform.isWindows ? 'explorer.exe' : Platform.isMacOS ? 'open' : 'xdg-open');
      expect(args, [root.path]);
      return ProcessResult(1, 0, '', '');
    });
    await expectLater(revealLocalAvailability(inspect,
        launch: (_, __) async => ProcessResult(1, 1, '', 'private diagnostics')),
        throwsStateError);
  });

  test('nested renamed ancestors use fresh names; directory reveal stays inside root', () async {
    RemoteFile node(String id, String? parent, String name, bool dir) =>
        RemoteFile(id, parent, name, dir, 0, false, 0, null);
    await Directory(p.join(root.path, 'new-name')).create();
    await File(p.join(root.path, 'new-name', 'a.txt')).writeAsString('local');
    final listings = <String?, List<RemoteFile>>{
      null: [node('root', null, 'Root', true)],
      'root': [node('nested', 'root', 'new-name', true)],
      'nested': [node('file', 'nested', 'a.txt', false)],
    };
    final states = await inspectBrowserAvailability(
      parentIds: ['root', 'nested'], folders: [folder],
      list: (parent) async => listings[parent]!,
      decrypt: (entry) => entry.nameEnc, comparisonKey: (name) => name.toLowerCase());
    expect(states['file']!.path, p.join(root.path, 'new-name', 'a.txt'));
    final rootState = await inspectLocalAvailability(
      ancestry: [(id: 'root', name: 'Root')], folders: [folder], isDir: true);
    await revealLocalAvailability(() async => rootState, launch: (_, args) async {
      expect(args, [root.path]);
      return ProcessResult(1, 0, '', '');
    });
  });

  test('fresh ancestor IDs/names and duplicate names fail safely', () async {
    RemoteFile node(String id, String? parent, String name, bool dir) =>
        RemoteFile(id, parent, name, dir, 0, false, 0, null);
    final remoteRoot = node('root', null, 'renamed remote root', true);
    final entry = node('file', 'root', 'a.txt', false);
    var siblings = [entry];
    var roots = [remoteRoot];
    Future<Map<String, LocalAvailability>> browser() => inspectBrowserAvailability(
      parentIds: ['root'], folders: [folder],
      list: (parent) async => parent == null ? roots : siblings,
      decrypt: (entry) => entry.nameEnc, comparisonKey: (name) => name.toLowerCase());
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    expect((await browser())['file']!.label, 'Local');
    siblings = [entry, node('other', 'root', 'A.TXT', false)];
    expect((await browser())['file']!.label, 'Unknown');
    siblings = [node('file', 'wrong-parent', 'a.txt', false)];
    expect((await browser())['file']!.label, 'Unknown');
    siblings = [node('file', 'root', 'unreadable', false)];
    final unreadable = await inspectBrowserAvailability(
      parentIds: ['root'], folders: [folder],
      list: (parent) async => parent == null ? roots : siblings,
      decrypt: (entry) {
        if (entry.id == 'file') throw StateError('Decryption failed');
        return entry.nameEnc;
      }, comparisonKey: (name) => name.toLowerCase());
    expect(unreadable['file']!.path, isNull);
    roots = [];
    expect(await browser(), isEmpty);
  });
}
