import 'dart:ui' show Tristate;

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

  testWidgets('compact direct destinations, chooser and honest selection', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final selected = <SessionDestination>[];
    final semantics = tester.ensureSemantics();
    for (final destination in SessionDestination.values) {
      await tester.pumpWidget(
        MaterialApp(
          home: SessionNavigation(
            selected: destination,
            onSelected: selected.add,
            child: const Scaffold(body: Text('Browser')),
          ),
        ),
      );
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      await tester.pumpAndSettle();
      final group = switch (destination) {
        SessionDestination.global || SessionDestination.devices => 'files',
        SessionDestination.search => 'search',
        SessionDestination.sync => 'sync',
        SessionDestination.activity => 'activity',
        _ => 'more',
      };
      for (final name in ['files', 'search', 'sync', 'activity', 'more']) {
        final item = find.byKey(ValueKey('navigation-$name'));
        expect(
          tester
              .getSemantics(item)
              .getSemanticsData()
              .flagsCollection.isSelected,
          name == group ? Tristate.isTrue : Tristate.isFalse,
        );
      }
    }
    semantics.dispose();
    await tester.tap(find.byKey(const ValueKey('navigation-files')));
    await tester.pumpAndSettle();
    expect(selected, isEmpty, reason: 'Files must not assume Global');
    expect(find.byKey(const ValueKey('menu-global')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-devices')), findsOneWidget);
    expect(find.byKey(const ValueKey('menu-trash')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu-devices')));
    await tester.pumpAndSettle();
    expect(selected, [SessionDestination.devices]);
    for (final destination in [
      SessionDestination.search,
      SessionDestination.sync,
      SessionDestination.activity,
    ]) {
      await tester.tap(find.byKey(ValueKey('navigation-${destination.name}')));
      await tester.pumpAndSettle();
      expect(selected.last, destination);
      expect(find.byType(BottomSheet), findsNothing);
    }
  });

  testWidgets(
    'compact keyboard traversal discovers and activates every destination',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final selected = <SessionDestination>[];
      await show(tester, 240, scale: 2, onSelected: selected.add);
      final reached = <String>[];
      for (var i = 0; i < 30; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final context = FocusManager.instance.primaryFocus?.context;
        String? name;
        context?.visitAncestorElements((element) {
          final key = element.widget.key;
          if (key is ValueKey<String> &&
              key.value.startsWith('navigation-') &&
              key.value != 'navigation-compact') {
            name = key.value;
            return false;
          }
          return true;
        });
        if (name != null && !reached.contains(name)) {
          reached.add(name!);
          expect(find.byKey(ValueKey(name!)).hitTestable(), findsOneWidget);
          if (name == 'navigation-search') {
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pumpAndSettle();
          }
        }
        if (reached.length == 5) break;
      }
      expect(reached, [
        'navigation-files',
        'navigation-search',
        'navigation-sync',
        'navigation-activity',
        'navigation-more',
      ]);
      expect(selected, [SessionDestination.search]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'very narrow 200 percent compact labels and targets stay reachable',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await show(tester, 240, scale: 2);
      tester.view.physicalSize = const Size(240, 600);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final bar = find.byKey(const ValueKey('navigation-compact'));
      expect(tester.getRect(bar).bottom, lessThanOrEqualTo(300));
      expect(
        tester.getSize(find.byType(Scaffold)).height,
        closeTo(300 - tester.getSize(bar).height, 1),
      );
      for (final name in ['files', 'search', 'sync', 'activity', 'more']) {
        final item = find.byKey(ValueKey('navigation-$name'));
        await tester.ensureVisible(item);
        await tester.pumpAndSettle();
        expect(tester.getSize(item).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
        expect(item.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byKey(const ValueKey('navigation-more')));
      await tester.pumpAndSettle();
      for (final name in ['trash', 'settings', 'manageDevices']) {
        final item = find.byKey(ValueKey('menu-$name'));
        await tester.scrollUntilVisible(
          item,
          100,
          scrollable: find.byType(Scrollable).last,
        );
        expect(tester.getSize(item).height, greaterThanOrEqualTo(48));
        expect(item.hitTestable(), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    },
  );

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
        await tester.ensureVisible(
          find.byKey(const ValueKey('navigation-more')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('navigation-more')));
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
        final direct =
            width < 600 &&
            [
              SessionDestination.search,
              SessionDestination.sync,
              SessionDestination.activity,
            ].contains(destination);
        if (width < 1200 && !direct) {
          await tester.tap(
            width < 600
                ? find.byKey(
                    ValueKey(
                      destination == SessionDestination.global ||
                              destination == SessionDestination.devices
                          ? 'navigation-files'
                          : 'navigation-more',
                    ),
                  )
                : find.byTooltip('Navigation destinations'),
          );
          await tester.pumpAndSettle();
        }
        final item = find.byKey(
          ValueKey(
            '${width < 1200 && !direct ? 'menu' : 'navigation'}-${destination.name}',
          ),
        );
        if (width < 1200 && !direct) {
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
