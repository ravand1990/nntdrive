import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/update_prompt.dart';
import 'package:nntdrive/updater.dart';

UpdateInfo info({
  List<ReleaseNote> notes = const [],
  String fallback = '',
  int omitted = 0,
}) =>
    UpdateInfo(
      version: '0.9.0',
      notes: fallback,
      releaseNotes: notes,
      olderNotesOmitted: omitted,
      assetName: 'nntdrive-0.9.0-linux-x64.tar.gz',
      assetUrl: Uri.parse('https://example.invalid/asset'),
      size: 1024,
    );

Future<void> pumpNotes(WidgetTester tester, UpdateInfo value,
    {double height = 600}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: height,
        child: UpdateNotesView(info: value),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one heading per version, newest first', (tester) async {
    await pumpNotes(
      tester,
      info(notes: const [
        ReleaseNote(version: '0.9.0', body: 'Nine changes'),
        ReleaseNote(version: '0.8.0', body: 'Eight changes'),
      ]),
    );
    expect(find.text('Changes in 0.9.0'), findsOneWidget);
    expect(find.text('Changes in 0.8.0'), findsOneWidget);
    expect(find.text('Nine changes'), findsOneWidget);
    expect(find.text('Eight changes'), findsOneWidget);
    final newest = tester.getTopLeft(find.text('Changes in 0.9.0')).dy;
    final older = tester.getTopLeft(find.text('Changes in 0.8.0')).dy;
    expect(newest, lessThan(older));
  });

  testWidgets('omitted older releases are reported', (tester) async {
    await pumpNotes(
      tester,
      info(
        notes: const [ReleaseNote(version: '0.9.0', body: 'Nine changes')],
        omitted: 3,
      ),
    );
    expect(find.text('3 older releases not shown.'), findsOneWidget);
  });

  testWidgets('a single omitted release reads in the singular',
      (tester) async {
    await pumpNotes(
      tester,
      info(
        notes: const [ReleaseNote(version: '0.9.0', body: 'Nine changes')],
        omitted: 1,
      ),
    );
    expect(find.text('1 older release not shown.'), findsOneWidget);
  });

  testWidgets('plain notes are still shown when there is no structure',
      (tester) async {
    await pumpNotes(tester, info(fallback: 'Single release notes'));
    expect(find.text('Single release notes'), findsOneWidget);
  });

  testWidgets('nothing is rendered when the feed published no notes',
      (tester) async {
    await pumpNotes(tester, info());
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a long history scrolls instead of overflowing the window',
      (tester) async {
    await pumpNotes(
      tester,
      info(
        notes: [
          for (var minor = 9; minor >= 1; minor--)
            ReleaseNote(
              version: '0.$minor.0',
              body: 'Changes for 0.$minor.0 ' * 20,
            ),
        ],
      ),
      height: 240,
    );
    expect(tester.takeException(), isNull);
    final scrollable = find.byType(SingleChildScrollView);
    expect(scrollable, findsOneWidget);
    await tester.drag(scrollable, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Changes in 0.9.0'), findsOneWidget);
  });
}
