import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/session_navigation.dart';

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: () => setState(() => count++),
    child: Text('Child count $count'),
  );
}

void main() {
  testWidgets(
    'compact navigation stays above keyboard without double child inset',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 600);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpWidget(
        MaterialApp(
          home: SessionNavigation(
            onSelected: (_) {},
            child: const Scaffold(
              body: SizedBox.expand(key: ValueKey('child-body')),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('navigation-compact'));
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(300));
      expect(
        tester.getSize(find.byKey(const ValueKey('child-body'))).height,
        closeTo(300 - tester.getSize(button).height, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  Future<void> show(
    WidgetTester tester,
    double width, {
    double scale = 1,
    ValueChanged<SessionDestination>? onSelected,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = Size(width, 900);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: SessionNavigation(
          onSelected: onSelected ?? (_) {},
          child: const Scaffold(body: _Counter()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final (width, scale, mode) in [
    (1440.0, 1.0, 'sidebar'),
    (1024.0, 1.0, 'rail'),
    (768.0, 1.0, 'rail'),
    (390.0, 1.0, 'compact'),
    (1440.0, 2.0, 'compact'),
    (390.0, 2.0, 'compact'),
  ]) {
    testWidgets('$width at ${scale}x uses $mode without overflow', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, width, scale: scale);
      expect(find.byKey(ValueKey('navigation-$mode')), findsOneWidget);
      if (mode == 'sidebar') {
        expect(
          tester
              .getSize(find.byKey(const ValueKey('navigation-sidebar')))
              .width,
          240,
        );
      }
      if (mode == 'rail') {
        expect(
          tester.getSize(find.byKey(const ValueKey('navigation-rail'))).width,
          72,
        );
      }
      if (mode == 'compact') {
        await tester.tap(find.byKey(const ValueKey('navigation-compact')));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('menu-manageDevices')),
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(find.text('Manage devices'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'labelled navigation is reachable and activatable with keyboard',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final selected = <SessionDestination>[];
      await show(tester, 1440, onSelected: selected.add);
      var reached = false;
      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final tile = FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<ListTile>();
        if (tile?.key == const ValueKey('navigation-search')) {
          reached = true;
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
          await tester.pumpAndSettle();
          break;
        }
      }
      expect(reached, isTrue);
      expect(selected, [SessionDestination.search]);
    },
  );

  testWidgets('collapse and breakpoint changes preserve child state identity', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await show(tester, 1440);
    final state = tester.state(find.byType(_Counter));
    await tester.tap(find.text('Child count 0'));
    await tester.pump();
    await tester.tap(find.byTooltip('Collapse navigation'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-rail')), findsOneWidget);
    await tester.tap(find.byTooltip('Expand navigation'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('navigation-sidebar')), findsOneWidget);
    for (final width in [1024.0, 768.0, 390.0, 1440.0]) {
      await show(tester, width);
      expect(identical(tester.state(find.byType(_Counter)), state), isTrue);
      expect(find.text('Child count 1'), findsOneWidget);
    }
  });

  testWidgets('sidebar, rail overlay and compact map every real destination', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <SessionDestination>[];
    for (final width in [1440.0, 1024.0, 390.0]) {
      selected.clear();
      await show(tester, width, onSelected: selected.add);
      for (final destination in SessionDestination.values) {
        if (width < 1200) {
          await tester.tap(
            width < 600
                ? find.byKey(const ValueKey('navigation-compact'))
                : find.byTooltip('Navigation destinations'),
          );
          await tester.pumpAndSettle();
        }
        final item = find.byKey(
          ValueKey(
            '${width < 1200 ? 'menu' : 'navigation'}-${destination.name}',
          ),
        );
        if (width < 1200) {
          await tester.scrollUntilVisible(
            item,
            100,
            scrollable: find.byType(Scrollable).last,
          );
        } else {
          await tester.ensureVisible(item);
        }
        await tester.pumpAndSettle();
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(selected.last, destination);
      }
      expect(selected, SessionDestination.values);
      expect(find.text('Favorites'), findsNothing);
      expect(find.text('Recent'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
