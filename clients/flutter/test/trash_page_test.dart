import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/trash_page.dart';

/// A trash page wired to recorded fakes: the backend, the name opener and the
/// restore call are all replaced, so these tests exercise the page's own
/// decisions instead of HTTP or native crypto.
class _Harness {
  List<TrashEntry> entries;
  List<String>? names;
  final List<({String id, bool toRoot})> restored = [];
  int loads = 0;
  Object? loadError;
  Object? restoreError;

  _Harness(this.entries);

  Future<TrashListing> load() async {
    loads++;
    if (loadError != null) throw loadError!;
    return TrashListing(30, List<TrashEntry>.of(entries));
  }

  Future<List<String>> decrypt(List<TrashEntry> items) async =>
      names ?? items.map((e) => 'name-${e.id}').toList();

  Future<void> restore(String id, {bool toRoot = false}) async {
    if (restoreError != null) throw restoreError!;
    restored.add((id: id, toRoot: toRoot));
    entries = entries.where((e) => e.id != id).toList();
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

Widget _page(_Harness harness) => MaterialApp(
      home: TrashPage(
        load: harness.load,
        decrypt: harness.decrypt,
        restore: harness.restore,
      ),
    );

void main() {
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

    expect(harness.restored, [(id: 'a', toRoot: false)]);
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
    expect(harness.restored, [(id: 'a', toRoot: true)]);
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
}
