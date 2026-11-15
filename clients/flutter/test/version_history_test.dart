import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/version_history.dart';

/// The dialog wired to recorded fakes: no HTTP and no native crypto, so these
/// tests exercise the restore decisions the dialog itself owns.
class _Harness {
  _Harness(this.versions);
  List<VersionInfo> versions;
  Object? loadError;
  Object? restoreError;
  int loads = 0;
  final List<String> restored = [];
  final List<String> downloaded = [];

  Future<List<VersionInfo>> load() async {
    loads++;
    if (loadError != null) throw loadError!;
    return List<VersionInfo>.of(versions);
  }

  Future<void> restore(VersionInfo version) async {
    if (restoreError != null) throw restoreError!;
    restored.add(version.revisionId);
  }

  void download(VersionInfo version) => downloaded.add(version.revisionId);
}

VersionInfo _version(String id, {int size = 2048, String at = _newest}) =>
    VersionInfo(id, null, size, at);

const String _newest = '2026-11-01T10:00:00Z';
const String _older = '2026-10-01T08:30:00Z';

Widget _dialog(
  _Harness harness, {
  String? current = 'new',
  bool withRestore = true,
  bool withDownload = true,
}) =>
    MaterialApp(
      home: Scaffold(
        body: VersionHistoryDialog(
          title: 'Report.pdf',
          currentVersion: current,
          load: harness.load,
          restore: withRestore ? harness.restore : null,
          download: withDownload ? harness.download : null,
        ),
      ),
    );

void main() {
  testWidgets('marks the current version and lists the earlier ones',
      (tester) async {
    final harness = _Harness([
      _version('new'),
      _version('old', size: 1024, at: _older),
    ]);
    await tester.pumpWidget(_dialog(harness));
    await tester.pumpAndSettle();

    expect(find.text('Version history — Report.pdf'), findsOneWidget);
    expect(find.text('Current version'), findsOneWidget);
    expect(
      find.text('2.0 KiB · ${formatVersionTime(_newest)}'),
      findsOneWidget,
    );
    expect(find.text(formatVersionTime(_older)), findsOneWidget);
    expect(find.text('1.0 KiB'), findsOneWidget);
    // Only an earlier version can be restored.
    expect(find.byKey(const ValueKey('version-restore-old')), findsOneWidget);
    expect(find.byKey(const ValueKey('version-restore-new')), findsNothing);
  });

  testWidgets('a restore waits for confirmation and can be cancelled',
      (tester) async {
    final harness = _Harness([
      _version('new'),
      _version('old', at: _older),
    ]);
    await tester.pumpWidget(_dialog(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('version-restore-old')));
    await tester.pumpAndSettle();
    expect(find.text('Restore an earlier version?'), findsOneWidget);
    expect(find.textContaining(formatVersionTime(_older)), findsWidgets);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(harness.restored, isEmpty);
    expect(find.text('Current version'), findsOneWidget);
    expect(find.textContaining('Restored the version from'), findsNothing);
  });

  testWidgets('a confirmed restore marks that version current', (tester) async {
    final harness = _Harness([
      _version('new'),
      _version('old', size: 1024, at: _older),
    ]);
    await tester.pumpWidget(_dialog(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('version-restore-old')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(harness.restored, ['old']);
    expect(
      find.text('Restored the version from ${formatVersionTime(_older)}.'),
      findsOneWidget,
    );
    // The restored revision is now the current one and the other stays listed.
    final currentRow = find.byKey(const ValueKey('version-row-old'));
    expect(
      find.descendant(of: currentRow, matching: find.text('Current version')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('version-restore-old')), findsNothing);
    expect(find.byKey(const ValueKey('version-restore-new')), findsOneWidget);
  });

  testWidgets('a failed restore keeps the current version and says why',
      (tester) async {
    final harness = _Harness([
      _version('new'),
      _version('old', at: _older),
    ])..restoreError = ApiException(409, 'conflict', 'pending content');
    await tester.pumpWidget(_dialog(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('version-restore-old')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Restore'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('The version was not restored'),
      findsOneWidget,
    );
    expect(find.text('Current version'), findsOneWidget);
    final currentRow = find.byKey(const ValueKey('version-row-new'));
    expect(
      find.descendant(of: currentRow, matching: find.text('Current version')),
      findsOneWidget,
    );
    // The restore control stays available so the user can retry.
    expect(find.byKey(const ValueKey('version-restore-old')), findsOneWidget);
  });

  testWidgets('an empty history explains what will appear there',
      (tester) async {
    final harness = _Harness([]);
    await tester.pumpWidget(_dialog(harness, current: null));
    await tester.pumpAndSettle();
    expect(find.textContaining('No versions yet'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry that reads the history again',
      (tester) async {
    final harness = _Harness([_version('new')]);
    harness.loadError = ApiException(0, 'network', 'offline');
    await tester.pumpWidget(_dialog(harness));
    await tester.pumpAndSettle();
    expect(find.textContaining('could not be read'), findsOneWidget);
    expect(harness.loads, 1);

    harness.loadError = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(harness.loads, 2);
    expect(find.text('Current version'), findsOneWidget);
  });

  testWidgets('downloading one version hands it to the caller', (tester) async {
    final harness = _Harness([
      _version('new'),
      _version('old', at: _older),
    ]);
    await tester.pumpWidget(_dialog(harness));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('version-download-old')));
    await tester.pumpAndSettle();
    expect(harness.downloaded, ['old']);
    // Downloading is not restoring: nothing became current.
    expect(harness.restored, isEmpty);
  });

  testWidgets('without a restore callback the history stays read-only',
      (tester) async {
    final harness = _Harness([
      _version('new'),
      _version('old', at: _older),
    ]);
    await tester.pumpWidget(_dialog(harness, withRestore: false));
    await tester.pumpAndSettle();
    expect(find.text('Restore'), findsNothing);
    expect(find.byKey(const ValueKey('version-download-old')), findsOneWidget);
  });

  test('sizes and timestamps stay readable without a parsable date', () {
    expect(formatVersionSize(0), '0 B');
    expect(formatVersionSize(999), '999 B');
    expect(formatVersionSize(1536), '1.5 KiB');
    expect(formatVersionSize(20 * 1024), '20 KiB');
    expect(formatVersionSize(3 * 1024 * 1024 * 1024), '3.0 GiB');
    expect(formatVersionTime('not-a-date'), 'not-a-date');
    expect(formatVersionTime(_older), isNot(contains('T')));
  });
}
