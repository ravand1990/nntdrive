import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/local_availability_widgets.dart';

void main() {
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
