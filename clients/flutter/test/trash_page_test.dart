import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/folder_picker.dart';
import 'package:nntdrive/trash_page.dart';

/// A trash page wired to recorded fakes: the backend, the name opener and the
/// restore call are all replaced, so these tests exercise the page's own
/// decisions instead of HTTP or native crypto.
class _Harness {
  List<TrashEntry> entries;
  List<String>? names;
  final List<({String id, String? parentId, bool toRoot})> restored = [];
  final List<String> purged = [];
  int emptyCalls = 0;
  int loads = 0;
  Object? loadError;
  Object? restoreError;
  Object? purgeError;

  _Harness(this.entries);

  Future<TrashListing> load() async {
    loads++;
    if (loadError != null) throw loadError!;
    return TrashListing(30, List<TrashEntry>.of(entries));
  }

  Future<List<String>> decrypt(List<TrashEntry> items) async =>
      names ?? items.map((e) => 'name-${e.id}').toList();

  Future<void> restore(String id,
      {String? parentId, bool toRoot = false}) async {
    if (restoreError != null) throw restoreError!;
    restored.add((id: id, parentId: parentId, toRoot: toRoot));
    entries = entries.where((e) => e.id != id).toList();
  }

  Future<void> purge(String id) async {
    if (purgeError != null) throw purgeError!;
    purged.add(id);
    entries = entries.where((e) => e.id != id).toList();
  }

  Future<void> emptyTrash() async {
    emptyCalls++;
    entries = [];
  }
}

TrashEntry _entry(
  String id, {
  bool isDir = false,
  int size = 2048,
  int daysLeft = 12,
  bool expired = false,
  bool parentPresent = true,
}) =>
    TrashEntry(
      id,
      'parent-$id',
      'sealed-name-$id',
      isDir,
      size,
      DateTime.utc(2026, 11, 14, 10, 30),
      DateTime.utc(2026, 12, 14, 10, 30),
      daysLeft,
      expired: expired,
      parentPresent: parentPresent,
    );

Widget _page(_Harness harness,
        {Future<FolderChoice?> Function()? pickFolder}) =>
    MaterialApp(
      home: TrashPage(
        load: harness.load,
        decrypt: harness.decrypt,
        restore: harness.restore,
        purge: harness.purge,
        emptyTrash: harness.emptyTrash,
        pickFolder: pickFolder,
      ),
    );

void main() {
  group('rewind', rewindTests);

  testWidgets('lists deleted items with their names, age and retention left',
      (tester) async {
    final harness = _Harness([
      _entry('a', isDir: true, size: 0, daysLeft: 9),
      _entry('b', size: 3 * 1024 * 1024, daysLeft: 1),
    ]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    expect(find.text('Trash'), findsOneWidget);
    expect(find.text('name-a'), findsOneWidget);
    expect(find.text('name-b'), findsOneWidget);
    expect(find.textContaining('Folder · deleted 2026-11-14 · 9 days left'),
        findsOneWidget);
    expect(find.textContaining('3.0 MB · deleted 2026-11-14 · 1 day left'),
        findsOneWidget);
    expect(find.textContaining('restorable for 30 days'), findsOneWidget);
    expect(find.text('Restore'), findsNWidgets(2));
  });

  testWidgets('restores into the original folder and reloads the list',
      (tester) async {
    final harness = _Harness([_entry('a')]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();

    expect(harness.restored, [(id: 'a', parentId: null, toRoot: false)]);
    expect(harness.loads, 2);
    expect(find.text('Nothing in the trash.'), findsOneWidget);
    expect(find.textContaining('Restored name-a'), findsOneWidget);
  });

  testWidgets('an item whose folder is gone asks before restoring to My files',
      (tester) async {
    final harness = _Harness([_entry('a', parentPresent: false)]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('The original folder is gone'), findsOneWidget);
    expect(harness.restored, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.restored, isEmpty, reason: 'cancel restores nothing');

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore to My files'));
    await tester.pumpAndSettle();
    expect(harness.restored, [(id: 'a', parentId: null, toRoot: true)]);
  });

  testWidgets('an item whose folder is gone can go into a chosen folder',
      (tester) async {
    final harness = _Harness([_entry('a', parentPresent: false)]);
    await tester.pumpWidget(_page(harness,
        pickFolder: () async => const FolderChoice('dest-1', 'Archive')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a folder…'), findsOneWidget);
    expect(harness.restored, isEmpty, reason: 'nothing happens before a choice');

    await tester.tap(find.text('Choose a folder…'));
    await tester.pumpAndSettle();

    expect(harness.restored,
        [(id: 'a', parentId: 'dest-1', toRoot: false)]);
    expect(find.textContaining('Restored name-a'), findsOneWidget);
  });

  testWidgets('the folder chooser can still restore to My files',
      (tester) async {
    final harness = _Harness([_entry('a', parentPresent: false)]);
    await tester.pumpWidget(_page(harness,
        pickFolder: () async => const FolderChoice(null, 'My files')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a folder…'));
    await tester.pumpAndSettle();

    expect(harness.restored, [(id: 'a', parentId: null, toRoot: true)]);
  });

  testWidgets('cancelling the folder chooser restores nothing',
      (tester) async {
    final harness = _Harness([_entry('a', parentPresent: false)]);
    await tester.pumpWidget(
        _page(harness, pickFolder: () async => null));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a folder…'));
    await tester.pumpAndSettle();

    expect(harness.restored, isEmpty);
    expect(find.text('name-a'), findsOneWidget);
  });

  testWidgets('an expired item stays listed but offers no restore', (tester) async {
    final harness = _Harness([_entry('a', expired: true, daysLeft: 0)]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    expect(find.textContaining('Retention passed'), findsOneWidget);
    expect(find.text('Cannot restore'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Restore'), findsNothing);
    expect(harness.restored, isEmpty);
  });

  testWidgets('a failed load explains itself and retries', (tester) async {
    final harness = _Harness([_entry('a')])..loadError = Exception('offline');
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be loaded'), findsOneWidget);
    harness.loadError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('name-a'), findsOneWidget);
  });

  testWidgets('a retention failure while restoring is explained', (tester) async {
    final harness = _Harness([_entry('a')])
      ..restoreError = ApiException(410, 'gone', 'retention');
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Restore'));
    await tester.pumpAndSettle();
    expect(find.textContaining('passed the retention window'), findsOneWidget);
    expect(find.text('name-a'), findsOneWidget);
  });

  testWidgets('unreadable names are shown as unavailable, never as ciphertext',
      (tester) async {
    final harness = _Harness([_entry('a')])..names = [''];
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    expect(find.text('Name unavailable'), findsOneWidget);
    expect(find.textContaining('sealed-name'), findsNothing);
  });

  testWidgets('permanent delete asks first and sends nothing on cancel',
      (tester) async {
    final harness = _Harness([_entry('a', isDir: true, size: 0)]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete permanently'));
    await tester.pumpAndSettle();
    expect(find.text('Delete permanently?'), findsOneWidget);
    expect(find.textContaining('cannot be retracted'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.purged, isEmpty, reason: 'cancel purges nothing');
    expect(find.text('name-a'), findsOneWidget);
  });

  testWidgets('a confirmed permanent delete removes the item and reloads',
      (tester) async {
    final harness = _Harness([_entry('a'), _entry('b')]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete permanently').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(harness.purged, ['a']);
    expect(harness.loads, 2);
    expect(find.text('name-a'), findsNothing);
    expect(find.text('name-b'), findsOneWidget);
    expect(find.textContaining('Deleted name-a permanently'), findsOneWidget);
  });

  testWidgets('an expired item can still be deleted permanently',
      (tester) async {
    final harness = _Harness([_entry('a', expired: true, daysLeft: 0)]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    expect(find.text('Cannot restore'), findsOneWidget);
    await tester.tap(find.byTooltip('Delete permanently'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();
    expect(harness.purged, ['a']);
    expect(find.text('Nothing in the trash.'), findsOneWidget);
  });

  testWidgets('empty trash asks first, then clears everything', (tester) async {
    final harness = _Harness([_entry('a'), _entry('b')]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Empty trash'));
    await tester.pumpAndSettle();
    expect(find.text('Empty the trash?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.emptyCalls, 0, reason: 'cancel empties nothing');

    await tester.tap(find.byTooltip('Empty trash'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Empty trash'));
    await tester.pumpAndSettle();
    expect(harness.emptyCalls, 1);
    expect(find.text('Nothing in the trash.'), findsOneWidget);
    expect(find.textContaining('Trash emptied'), findsOneWidget);
  });

  testWidgets('empty trash is unavailable once the trash is empty',
      (tester) async {
    final harness = _Harness([]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    final button = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.delete_sweep));
    expect(button.onPressed, isNull,
        reason: 'an empty trash offers nothing to empty');
  });

  testWidgets('a failed permanent delete explains itself and keeps the item',
      (tester) async {
    final harness = _Harness([_entry('a')])
      ..purgeError = ApiException(409, 'conflict', 'changed');
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Delete permanently'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(find.text('name-a'), findsOneWidget);
    expect(find.textContaining('changed or its folder is gone'), findsOneWidget);
  });
}

RewindItem _rewindItem(String id, {int targetSize = 10}) => RewindItem(
      id,
      'parent-$id',
      'sealed-name-$id',
      'current-$id',
      'target-$id',
      targetSize,
      targetSize,
      DateTime.utc(2026, 11, 10, 12),
    );

class _RewindHarness extends _Harness {
  _RewindHarness(super.entries);

  RewindPreview? plan;
  Object? previewError;
  RewindResult? result;
  Object? applyError;
  final List<DateTime> previews = [];
  final List<String?> previewScopes = [];
  final List<({DateTime before, List<RewindItem> items, String? scope})>
      applied = [];

  Future<RewindPreview> preview(DateTime before, {String? scopeId}) async {
    previews.add(before);
    previewScopes.add(scopeId);
    if (previewError != null) throw previewError!;
    return plan ??
        RewindPreview(before, scopeId, RewindCounts(0, 0, 0, 0), const [], null);
  }

  Future<RewindResult> apply(DateTime before, List<RewindItem> items,
      {String? scopeId}) async {
    if (applyError != null) throw applyError!;
    applied.add((before: before, items: items, scope: scopeId));
    return result ?? RewindResult(items.length, 0, const []);
  }

  Future<List<String>> decryptRewind(List<RewindItem> items) async =>
      items.map((i) => 'rewind-${i.id}').toList();
}

Widget _rewindPage(_RewindHarness harness,
        {Future<FolderChoice?> Function()? pickFolder}) =>
    MaterialApp(
      home: TrashPage(
        load: harness.load,
        decrypt: harness.decrypt,
        restore: harness.restore,
        purge: harness.purge,
        emptyTrash: harness.emptyTrash,
        previewRewind: harness.preview,
        applyRewind: harness.apply,
        decryptRewind: harness.decryptRewind,
        pickFolder: pickFolder,
      ),
    );

void rewindTests() {
  testWidgets('the rewind action is only offered when it can be planned',
      (tester) async {
    final harness = _RewindHarness([_entry('a')]);
    await tester.pumpWidget(_page(harness));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Rewind to an earlier date'), findsNothing);

    await tester.pumpWidget(_rewindPage(harness));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Rewind to an earlier date'), findsOneWidget);
  });

  testWidgets('a rewind shows what would change and only applies on confirm',
      (tester) async {
    final harness = _RewindHarness([_entry('a')])
      ..plan = RewindPreview(
        DateTime.utc(2026, 11, 8),
        null,
        RewindCounts(2, 3, 1, 0),
        [_rewindItem('x'), _rewindItem('y')],
        null,
      );
    await tester.pumpWidget(_rewindPage(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rewind to an earlier date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 days ago'));
    await tester.pumpAndSettle();

    expect(harness.previews, hasLength(1));
    expect(harness.previewScopes.single, isNull,
        reason: 'the whole account is the default scope');
    expect(find.textContaining('2 files would go back to an earlier version'),
        findsOneWidget);
    expect(find.textContaining('1 created after that date'), findsOneWidget);
    expect(find.text('rewind-x'), findsOneWidget);
    expect(find.text('rewind-y'), findsOneWidget);
    expect(find.textContaining('cannot be retracted'), findsOneWidget);
    expect(harness.applied, isEmpty, reason: 'nothing changes before confirm');

    await tester.tap(find.text('Rewind 2 files'));
    await tester.pumpAndSettle();

    expect(harness.applied, hasLength(1));
    expect(harness.applied.single.items.map((i) => i.id), ['x', 'y']);
    expect(harness.applied.single.items.first.targetRevision, 'target-x');
    expect(harness.applied.single.scope, isNull);
    expect(find.textContaining('Rewound 2 files'), findsOneWidget);
  });

  testWidgets('a date with nothing to change cannot be confirmed',
      (tester) async {
    final harness = _RewindHarness([_entry('a')])
      ..plan = RewindPreview(
          DateTime.utc(2026, 11, 8), null, RewindCounts(0, 4, 0, 0), const [],
          null);
    await tester.pumpWidget(_rewindPage(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rewind to an earlier date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1 day ago'));
    await tester.pumpAndSettle();

    expect(find.text('Nothing would change.'), findsOneWidget);
    final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Rewind'));
    expect(button.onPressed, isNull);
  });

  testWidgets('a failed plan explains itself and changes nothing',
      (tester) async {
    final harness = _RewindHarness([_entry('a')])
      ..previewError = ApiException(500, 'boom', 'internal');
    await tester.pumpWidget(_rewindPage(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rewind to an earlier date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('30 days ago'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(harness.applied, isEmpty);
  });

  testWidgets('a partly refused rewind reports what was left alone',
      (tester) async {
    final harness = _RewindHarness([_entry('a')])
      ..plan = RewindPreview(DateTime.utc(2026, 11, 8), null,
          RewindCounts(1, 0, 0, 0), [_rewindItem('x')], null)
      ..result = RewindResult(1, 0, [(id: 'x', reason: 'the file changed')]);
    await tester.pumpWidget(_rewindPage(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rewind to an earlier date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 days ago'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rewind 1 file'));
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be changed'), findsOneWidget);
  });

  testWidgets('a rewind can be narrowed to one folder and replans for it',
      (tester) async {
    final harness = _RewindHarness([_entry('a')])
      ..plan = RewindPreview(DateTime.utc(2026, 11, 8), null,
          RewindCounts(1, 0, 0, 0), [_rewindItem('x')], null);
    await tester.pumpWidget(_rewindPage(harness,
        pickFolder: () async => const FolderChoice('f-1', 'Archive')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rewind to an earlier date'));
    await tester.pumpAndSettle();
    expect(find.text('Scope: the whole account'), findsOneWidget);

    await tester.tap(find.text('7 days ago'));
    await tester.pumpAndSettle();
    expect(harness.previewScopes, [null]);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();
    expect(find.text('Scope: Archive'), findsOneWidget);
    expect(find.textContaining('Puts the files in Archive back'), findsOneWidget);
    expect(harness.previewScopes, [null, 'f-1'],
        reason: 'a new scope is planned again, never confirmed against the old plan');

    await tester.tap(find.text('Rewind 1 file'));
    await tester.pumpAndSettle();
    expect(harness.applied.single.scope, 'f-1');
  });

  testWidgets('without a folder chooser a rewind stays account-wide',
      (tester) async {
    final harness = _RewindHarness([_entry('a')]);
    await tester.pumpWidget(_rewindPage(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Rewind to an earlier date'));
    await tester.pumpAndSettle();

    expect(find.text('Scope: the whole account'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Change'), findsNothing);
  });
}
