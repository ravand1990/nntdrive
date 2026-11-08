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

  test('browser equality is fresh, file-only and subordinate to errors/conflicts', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    var calls = 0;
    var succeeds = true;
    var throws = false;
    var entry = RemoteFile('file', 'root', 'a.txt', false, 5, false, 1,
        '11111111-1111-4111-8111-111111111111');
    Future<LocalAvailability> browser() async {
      final states = await inspectBrowserAvailability(
        parentIds: ['root'], folders: [folder],
        list: (parent) async => parent == null
            ? [RemoteFile('root', null, 'Remote', true, 0, false, 1, null)]
            : [entry],
        decrypt: (file) => file.nameEnc,
        comparisonKey: (name) => name.toLowerCase(),
        verifyFile: (config, relative, remote) async {
          expect(config, same(folder));
          expect(relative, 'a.txt');
          expect(remote.currentVersion, entry.currentVersion);
          calls++;
          if (throws) throw StateError('unreadable journal');
          return succeeds;
        },
      );
      return states['file']!;
    }
    var state = await browser();
    expect(state.verifiedAtRefresh, isTrue);
    expect(state.displayExplanation, contains('listed remote revision'));
    folder.running = true;
    expect(state.displayExplanation, contains('content equality is not verified'));
    expect((await browser()).verifiedAtRefresh, isFalse);
    expect(calls, 1);
    folder.running = false;
    expect(state.withoutEquality().verifiedAtRefresh, isFalse);
    expect(state.withoutEquality().displayExplanation,
        contains('content equality is not verified'));
    expect(state.withoutEquality().path, state.path);
    succeeds = false;
    expect((await browser()).verifiedAtRefresh, isFalse);
    throws = true;
    expect((await browser()).displayExplanation, contains('content equality is not verified'));
    throws = false;
    succeeds = true;
    folder.lastReport = {'item_errors': [
      {'paths': ['a.txt'], 'operation': 'download', 'code': 'io'}
    ]};
    state = await browser();
    expect(state.displayLabel, 'Error');
    expect(state.verifiedAtRefresh, isFalse);
    folder.lastReport = null;
    folder.conflictFiles = ['a.txt'];
    expect((await browser()).displayLabel, 'Conflict');
    folder.conflictFiles = [];
    entry = RemoteFile('file', 'root', 'a.txt', false, 5, false, 1, null);
    expect((await browser()).verifiedAtRefresh, isFalse);
    await File(p.join(root.path, 'a.txt')).delete();
    expect((await browser()).displayLabel, 'Cloud only');
    await Directory(p.join(root.path, 'a.txt')).create();
    entry = RemoteFile('file', 'root', 'a.txt', true, 0, false, 1, null);
    expect((await browser()).verifiedAtRefresh, isFalse);
    expect(calls, 3);
  });

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
    expect(state.displayLabel, 'Conflict');
    expect(state.displayExplanation, contains('conflict copy'));
    folder.running = false;
    expect(state.displayLabel, 'Conflict');
  });

  test('only the exact active transfer is Syncing, never siblings or completion', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    final state = await inspect();
    folder.running = true;
    expect(state.displayLabel, 'Local');
    for (final path in ['other/a.txt', 'a.txt.extra', '../a.txt', 'A.TXT']) {
      folder.progress = {'path': path, 'complete': false};
      expect(state.displayLabel, 'Local', reason: path);
    }
    folder.progress = {'path': 'a.txt', 'complete': false};
    expect(state.displayLabel, 'Syncing');
    expect(state.displayExplanation, contains('not verified'));
    folder.progress = {'path': 'a.txt', 'complete': true};
    expect(state.displayLabel, 'Local');
    folder.running = false;
    folder.progress = {'path': 'a.txt', 'complete': false};
    expect(state.displayLabel, 'Local');
    folder.lastError = 'folder failure';
    expect(state.displayLabel, 'Local');
    await File(state.path!).delete();
    final missing = await inspect();
    folder.running = true;
    expect(missing.displayLabel, 'Syncing');
    expect(missing.path, isNull);
    folder.progress = {'path': 'a.txt', 'complete': true};
    expect(missing.displayLabel, 'Cloud only');
    await Directory(p.join(root.path, 'a.txt')).create();
    final directory = await inspect(isDir: true);
    folder.progress = {'path': 'a.txt', 'complete': false};
    expect(directory.displayLabel, 'Local');
    final unsafe = await inspect();
    expect(unsafe.displayLabel, 'Error');
    expect(unsafe.path, isNull);
  });

  test('structured failures match exact paths only and never expose diagnostics', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    final state = await inspect();
    folder.lastError = 'PRIVATE DIAGNOSTIC';
    folder.lastReport = {'errors': [['upload a.txt', 'PRIVATE DIAGNOSTIC']]};
    expect(state.displayLabel, 'Local'); // No parsing legacy labels.
    for (final path in ['other/a.txt', 'A.TXT', 'a.txt.extra', '../a.txt']) {
      folder.lastReport = {'item_errors': [{'paths': [path], 'operation': 'upload', 'code': 'remote'}]};
      expect(state.displayLabel, 'Local');
    }
    folder.lastReport = {'item_errors': [{'paths': ['a.txt'], 'operation': 'upload', 'code': 'remote', 'message': 'PRIVATE DIAGNOSTIC'}]};
    expect(state.displayLabel, 'Error');
    expect(state.displayExplanation, contains('last completed sync attempt'));
    expect(state.displayExplanation, isNot(contains('PRIVATE')));
    expect(state.path, isNotNull); // Failure does not erase safe disk presence.
    folder.running = true;
    expect(state.displayLabel, 'Local'); // Previous reports are not current events.
    folder.progress = {'path': 'a.txt', 'complete': false};
    expect(state.displayLabel, 'Syncing');
    folder.running = false;
    folder.conflictFiles = ['a.txt'];
    expect((await inspect()).displayLabel, 'Conflict');
    folder.conflictFiles = [];
    await File(state.path!).delete();
    expect((await inspect()).displayLabel, 'Error');
    folder.lastReport = {'item_errors': []};
    expect((await inspect()).displayLabel, 'Cloud only');
    for (final malformed in [null, 'oops', [null, 1, {}, {'paths': 'a.txt'}]]) {
      folder.lastReport = {'item_errors': malformed};
      expect((await inspect()).displayLabel, 'Cloud only');
    }
  });

  test('original and copy show Conflict only while a safe copy exists', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('canonical');
    const copy = 'a (conflict device 123).txt';
    folder.conflictFiles = [copy];
    expect((await inspect()).label, 'Local');
    final preserved = await File(p.join(root.path, copy)).writeAsString('mine');
    final state = await inspect();
    expect(state.label, 'Conflict');
    expect(state.path, p.join(root.path, 'a.txt'));
    final copyState = await inspectLocalAvailability(
        ancestry: [(id: 'root', name: 'Remote'), (id: 'copy', name: copy)],
        folders: [folder], isDir: false);
    expect(copyState.label, 'Conflict');
    await preserved.delete();
    expect((await inspect()).label, 'Local');
    await Directory(preserved.path).create();
    expect((await inspect()).label, 'Local');
    await Directory(preserved.path).delete();
    folder.conflictFiles = ['nested/$copy', '../$copy'];
    expect((await inspect()).label, 'Local');
    if (!Platform.isWindows) {
      folder.conflictFiles = [copy];
      final outside = await File(p.join(sandbox.path, 'outside')).writeAsString('private');
      await Link(preserved.path).create(outside.path);
      expect((await inspect()).label, 'Local');
    }
  });

  test('missing original retains safe same-directory conflict without reveal', () async {
    const copy = 'a (conflict device 123).txt';
    folder.conflictFiles = [copy];
    final preserved = await File(p.join(root.path, copy)).writeAsString('mine');
    final state = await inspect();
    expect(state.label, 'Conflict');
    expect(state.path, isNull);
    expect(state.explanation, contains('original is missing'));
    folder.running = true;
    folder.progress = {'path': 'a.txt', 'complete': false};
    expect(state.displayLabel, 'Conflict');
    await expectLater(revealLocalAvailability(inspect,
        launch: (_, __) async => fail('Missing original must not launch')),
        throwsStateError);
    await preserved.delete();
    expect((await inspect()).label, 'Cloud only');
    await Directory(preserved.path).create();
    expect((await inspect()).label, 'Cloud only');
    await Directory(preserved.path).delete();
    if (!Platform.isWindows) {
      final outside = await File(p.join(sandbox.path, 'outside')).writeAsString('mine');
      await Link(preserved.path).create(outside.path);
      expect((await inspect()).label, 'Cloud only');
    }
  });

  test('missing ancestor never infers conflicts from another directory', () async {
    const copy = 'a (conflict device 123).txt';
    await File(p.join(root.path, copy)).writeAsString('mine');
    folder.conflictFiles = ['missing/$copy', '../$copy', copy];
    final state = await inspectLocalAvailability(
        ancestry: [(id: 'root', name: 'Root'), (id: 'dir', name: 'missing'),
          (id: 'file', name: 'a.txt')], folders: [folder], isDir: false);
    expect(state.label, 'Cloud only');
    expect(state.path, isNull);
    expect((await inspect(isDir: true)).label, 'Cloud only');
  });

  test('conflict in another directory never marks same-basename original', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('local');
    await Directory(p.join(root.path, 'nested')).create();
    const copy = 'nested/a (conflict device 123).txt';
    await File(p.join(root.path, copy)).writeAsString('mine');
    folder.conflictFiles = [copy];
    expect((await inspect()).label, 'Local');
    final nested = await File(p.join(root.path, 'nested', 'a.txt')).writeAsString('theirs');
    final state = await inspectLocalAvailability(
        ancestry: [(id: 'root', name: 'Remote'), (id: 'nested', name: 'nested'),
          (id: 'file', name: 'a.txt')], folders: [folder], isDir: false);
    expect(state.label, 'Conflict');
    expect(state.path, nested.path);
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
