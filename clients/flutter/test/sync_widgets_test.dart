import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_widgets.dart';

void main() {
  testWidgets('progress shows native byte counts and does not imply commit',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SyncTransferProgress(event: {
      'path': 'dir/file.txt',
      'direction': 'upload',
      'bytes': 4096,
      'total': 8192,
      'complete': false,
    }))));
    expect(find.text('upload · dir/file.txt'), findsOneWidget);
    expect(find.text('4096 / 8192 bytes'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        0.5);
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SyncTransferProgress(event: {
      'path': 'empty',
      'direction': 'download',
      'bytes': 0,
      'total': 0,
      'complete': false,
    }))));
    expect(find.text('0 / 0 bytes · verifying / committing'), findsOneWidget);
    expect(
        tester
            .widget<LinearProgressIndicator>(
                find.byType(LinearProgressIndicator))
            .value,
        isNull);
  });
  for (final choice in {
    'Keep mine': 'mine',
    'Keep theirs': 'theirs',
    'Keep both': 'both'
  }.entries) {
    testWidgets('${choice.key} returns explicit choice and explains recovery',
        (tester) async {
      String? result;
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => TextButton(
                    onPressed: () async {
                      result = await showDialog<String>(
                          context: context,
                          builder: (_) => const ConflictChoiceDialog(
                              original: 'report.txt',
                              copy: 'report (conflict dev T).txt'));
                    },
                    child: const Text('Review'),
                  ))));
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(
          find.textContaining('Neither version is deleted.'), findsOneWidget);
      await tester.tap(find.text(choice.key));
      await tester.pumpAndSettle();
      expect(result, choice.value);
    });
  }
  test('conflict path proposals retain directory and extension', () {
    expect(originalConflictPath('dir/report (conflict dev T).txt'),
        'dir/report.txt');
    expect(originalConflictPath('dir/.hidden (conflict dev T)'), 'dir/.hidden');
    expect(originalConflictPath('normal.txt'), isNull);
  });
}
