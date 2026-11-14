import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nntdrive/app_layout.dart';

/// Fills whatever box it is given so the frame's own constraints are visible.
Widget _content() => Container(key: const Key('content'), color: Colors.blue);

void main() {
  testWidgets('content stays in a readable column on a tablet window',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppContentFrame(child: _content())),
    ));

    final rect = tester.getRect(find.byKey(const Key('content')));
    expect(rect.width, appMaxContentWidth);
    expect(rect.center.dx, closeTo(600, 0.5));
  });

  testWidgets('content keeps the full phone width', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: AppContentFrame(child: _content())),
    ));

    final rect = tester.getRect(find.byKey(const Key('content')));
    expect(rect.width, 400);
    expect(rect.left, 0);
  });

  testWidgets('bottom padding clears an open keyboard and the nav bar',
      (tester) async {
    late EdgeInsets keyboard;
    late EdgeInsets barOnly;
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          padding: EdgeInsets.only(bottom: 24),
          viewInsets: EdgeInsets.only(bottom: 300),
        ),
        child: Builder(builder: (context) {
          keyboard = appBottomBarPadding(context);
          return const SizedBox();
        }),
      ),
    ));
    expect(keyboard.bottom, 300);

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(padding: EdgeInsets.only(bottom: 24)),
        child: Builder(builder: (context) {
          barOnly = appBottomBarPadding(context);
          return const SizedBox();
        }),
      ),
    ));
    expect(barOnly.bottom, 24);
  });

  test('system bar style is a value type for both brightnesses', () {
    expect(
        appSystemUiOverlayStyle(Brightness.light), isA<SystemUiOverlayStyle>());
    expect(
        appSystemUiOverlayStyle(Brightness.dark), isA<SystemUiOverlayStyle>());
  });
}
