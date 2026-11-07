import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/local_availability_widgets.dart';
import 'package:nntdrive/sync_controller.dart';

void main() {
  testWidgets('active transfer labels only its row and never enables absent reveal', (tester) async {
    final folder = SyncFolderConfig(id: 'folder', name: 'Folder',
        localPath: '/fixture', remoteRootId: 'root')
      ..running = true
      ..progress = {'path': 'a.txt', 'complete': false};
    final active = LocalAvailability('Cloud only', 'No local copy.',
        folder: folder, relativePath: 'a.txt');
    final other = LocalAvailability('Local', 'Presence only.',
        folder: folder, relativePath: 'b.txt', path: '/fixture/b.txt');
    Future<void> render() => tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      LocalAvailabilityLabel(state: active, details: 'A'),
      LocalAvailabilityLabel(state: other, details: 'B'),
      LocalRevealButton(state: active, onReveal: () => fail('Absent file revealed')),
    ]))));
    await render();
    expect(find.text('A · Syncing'), findsOneWidget);
    expect(find.text('B · Local'), findsOneWidget);
    expect(tester.widget<IconButton>(find.byType(IconButton)).onPressed, isNull);
    folder.progress = {'path': 'a.txt', 'complete': true};
    await render();
    expect(find.text('A · Cloud only'), findsOneWidget);
    expect(find.textContaining('Syncing'), findsNothing);
  });

  testWidgets('cloud-only and unknown reveal are disabled with text explanations', (tester) async {
    for (final state in [
      const LocalAvailability('Cloud only', 'No copy exists at the expected synced path.'),
      LocalAvailability.unknown,
      const LocalAvailability('Not covered', 'No configured sync folder covers this entry.'),
    ]) {
      var revealed = false;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
        LocalAvailabilityLabel(state: state, details: 'File'),
        LocalRevealButton(state: state, onReveal: () => revealed = true),
      ]))));
      expect(find.text('File · ${state.label}'), findsOneWidget);
      final button = tester.widget<IconButton>(find.byType(IconButton));
      expect(button.onPressed, isNull);
      expect(button.tooltip, contains(state.explanation));
      expect(revealed, isFalse);
    }
  });

  testWidgets('local reveal is enabled and status is not color-only', (tester) async {
    const state = LocalAvailability('Local', 'Presence only, not verified content.', path: '/fixture/file');
    var revealed = false;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Column(children: [
      const LocalAvailabilityLabel(state: state, details: 'File'),
      LocalRevealButton(state: state, onReveal: () => revealed = true),
    ]))));
    expect(find.text('File · Local'), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    expect(revealed, isTrue);
  });
}
