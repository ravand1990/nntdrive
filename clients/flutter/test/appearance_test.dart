import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/appearance.dart';
import 'package:nntdrive/browser_views.dart';
import 'package:nntdrive/device_onboarding.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/secure_keyfile.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'browser_views_test.dart' show file;
import 'onboarding_updates_test.dart' show until;
import 'session_widget_test.dart' show SessionApi;

Future<void> openAppearance(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Account'));
  await tester.pumpAndSettle();
  final option = find.text('Appearance');
  await tester.scrollUntilVisible(
    option,
    200,
    scrollable: find.byType(Scrollable).last,
  );
  await tester.tap(option);
  await tester.pumpAndSettle();
  expect(find.byType(AppearanceDialog), findsOneWidget);
}

Future<void> unlock(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'appearance password');
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
  await until(
    tester,
    () =>
        find.byType(FilesPage).evaluate().isNotEmpty ||
        (find.byType(DeviceOnboardingPage).evaluate().isNotEmpty &&
            tester
                .widgetList<TextField>(find.byType(TextField))
                .any((f) => f.enabled != false)),
  );
  if (find.byType(DeviceOnboardingPage).evaluate().isNotEmpty) {
    // Default suggestions depend on the runner's OS/device identity. Keep the
    // later folder-filter assertion independent of that installed environment.
    await tester.enterText(find.byType(TextField), 'Device');
    await tester.runAsync(() async {
      await tester.tap(
        find.widgetWithText(FilledButton, 'Confirm device name'),
      );
    });
  }
  await until(
    tester,
    () => find.byType(BrowserFilesView).evaluate().isNotEmpty,
  );
}

Future<({SharedPreferences prefs, SessionApi api})> setup(
  WidgetTester tester, {
  String? density,
}) async {
  final bridge = NativeBridge.instance;
  final account = (await tester.runAsync(
    () => bridge.generateAccountAsync('appearance password'),
  ))!;
  final keyfile = jsonEncode(account['keyfile']);
  final handle = bridge.unlock(keyfile, 'appearance password')['handle'] as int;
  final api = SessionApi(
    account['account_id'] as String,
    bridge.sealName(handle, SessionApi.node, 'Device'),
  );
  bridge.lock(handle);
  SharedPreferences.setMockInitialValues({
    'token': 'fixture',
    'keyfile': keyfile,
    'accountId': account['account_id'],
    'email': 'test@example.invalid',
    'server': 'http://127.0.0.1:1',
    'updateAutoCheck': false,
    if (density != null) 'browserDensity': density,
  });
  final prefs = await SharedPreferences.getInstance();
  // Appearance tests must not migrate fixture credentials into a real runner's
  // credential manager (which also legitimately removes the legacy pref).
  await tester.pumpWidget(
    NntDriveApp(
      prefs: prefs,
      apiFactory: (_, _) => api,
      keyfileVault: KeyfileVault(prefs: prefs),
    ),
  );
  await tester.pumpAndSettle();
  await unlock(tester);
  return (prefs: prefs, api: api);
}

void main() {
  test('unknown and absent density default to comfortable', () {
    for (final value in [null, '', 'invalid', 'COMPACT', 'comfortable']) {
      expect(BrowserDensity.fromPreference(value), BrowserDensity.comfortable);
    }
    expect(BrowserDensity.fromPreference('compact'), BrowserDensity.compact);
  });

  testWidgets('production theme choices persist and follow system brightness', (
    tester,
  ) async {
    final fixture = await setup(tester);
    final page = tester.widget<FilesPage>(find.byType(FilesPage));
    final state = tester.state(find.byType(FilesPage));
    for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
      await openAppearance(tester);
      await tester.tap(
        find.text(switch (mode) {
          ThemeMode.dark => 'Dark',
          ThemeMode.light => 'Light',
          ThemeMode.system => 'System',
        }),
      );
      await tester.pumpAndSettle();
      expect(fixture.prefs.getInt('theme'), mode.index);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        mode,
      );
      expect(
        tester
            .widget<FilesPage>(find.byType(FilesPage, skipOffstage: false))
            .themeMode,
        mode,
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.state(find.byType(FilesPage)), same(state));
      expect(
        tester.widget<FilesPage>(find.byType(FilesPage)).session,
        same(page.session),
      );
      for (final brightness in Brightness.values) {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        await tester.pumpAndSettle();
        expect(
          Theme.of(tester.element(find.byType(BrowserFilesView))).brightness,
          mode == ThemeMode.system
              ? brightness
              : mode == ThemeMode.dark
              ? Brightness.dark
              : Brightness.light,
        );
      }
    }
    tester.platformDispatcher.clearPlatformBrightnessTestValue();
    // Recreate the app (not merely the dialog) from the persisted preference.
    page.onTheme(ThemeMode.dark);
    await tester.pumpAndSettle();
    page.onSignOut();
    await until(tester, () => find.byType(FilesPage).evaluate().isEmpty);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      NntDriveApp(
        prefs: fixture.prefs,
        keyfileVault: KeyfileVault(prefs: fixture.prefs),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.dark,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'production density wiring persists recreates and preserves browser state',
    (tester) async {
      final fixture = await setup(tester, density: 'invalid');
      final page = tester.widget<FilesPage>(find.byType(FilesPage));
      final state = tester.state(find.byType(FilesPage));
      expect(
        tester.widget<BrowserFilesView>(find.byType(BrowserFilesView)).density,
        BrowserDensity.comfortable,
      );
      await tester.tap(find.text('Grid'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Dev');
      await tester.pumpAndSettle();
      final original = tester
          .widget<BrowserFilesView>(find.byType(BrowserFilesView))
          .files
          .single;
      await openAppearance(tester);
      await tester.tap(find.text('Compact'));
      await tester.pumpAndSettle();
      expect(fixture.prefs.getString('browserDensity'), 'compact');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      var view = tester.widget<BrowserFilesView>(find.byType(BrowserFilesView));
      expect(view.density, BrowserDensity.compact);
      expect(view.view, BrowserView.grid);
      expect(view.files.single, same(original));
      expect(tester.state(find.byType(FilesPage)), same(state));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Dev',
      );
      expect(
        tester.widget<FilesPage>(find.byType(FilesPage)).sync,
        same(page.sync),
      );
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      view.onOpen(original);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Up one folder'), findsOneWidget);
      await openAppearance(tester);
      await tester.tap(find.text('Comfortable'));
      await tester.pumpAndSettle();
      expect(fixture.prefs.getString('browserDensity'), 'comfortable');
      await tester.tap(find.text('Compact'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Up one folder'), findsOneWidget);
      // Drain and lock the first app, then recreate and unlock with the saved density.
      final savedAuth = {
        for (final key in ['token', 'keyfile', 'accountId', 'email', 'server'])
          key: fixture.prefs.getString(key)!,
      };
      page.onSignOut();
      await until(tester, () => find.byType(FilesPage).evaluate().isEmpty);
      for (final entry in savedAuth.entries) {
        await fixture.prefs.setString(entry.key, entry.value);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        NntDriveApp(
          prefs: fixture.prefs,
          apiFactory: (_, _) => fixture.api,
          keyfileVault: KeyfileVault(prefs: fixture.prefs),
        ),
      );
      await tester.pumpAndSettle();
      await unlock(tester);
      expect(
        tester.widget<BrowserFilesView>(find.byType(BrowserFilesView)).density,
        BrowserDensity.compact,
      );
      tester.widget<FilesPage>(find.byType(FilesPage)).onSignOut();
      await until(tester, () => find.byType(FilesPage).evaluate().isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final mode in BrowserView.values) {
    for (final width in [320.0, 800.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets(
          '${mode.name} $width $scale density changes real spacing with 48dp actions',
          (tester) async {
            tester.view.physicalSize = Size(width, 900);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final heights = <double>[];
            for (final density in BrowserDensity.values) {
              await tester.pumpWidget(
                MaterialApp(
                  home: MediaQuery(
                    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                    child: Scaffold(
                      body: BrowserFilesView(
                        density: density,
                        view: mode,
                        files: [file('one'), file('two')],
                        nameFor: (f) => 'Long name for ${f.id}',
                        availabilityFor: (_) => LocalAvailability.unknown,
                        pinned: (_) => false,
                        onOpen: (_) {},
                        onActions: (_) {},
                        onReveal: (_) {},
                        onDetails: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              heights.add(
                tester.getSize(find.byType(BrowserFileTile).first).height,
              );
              for (final button in find.byType(IconButton).evaluate()) {
                final size = tester.getSize(find.byWidget(button.widget));
                expect(size.width, greaterThanOrEqualTo(48));
                expect(size.height, greaterThanOrEqualTo(48));
              }
              expect(
                tester.getSize(find.byType(InkWell).first).height,
                greaterThanOrEqualTo(48),
              );
              expect(tester.takeException(), isNull);
            }
            expect(heights.last, lessThan(heights.first));
          },
        );
      }
    }
  }

  testWidgets(
    'appearance dialog narrow 200 percent choices scroll and retain 48dp targets',
    (tester) async {
      tester.view.physicalSize = const Size(320, 560);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MediaQuery(
                  data: const MediaQueryData(textScaler: TextScaler.linear(2)),
                  child: AppearanceDialog(
                    themeMode: ThemeMode.system,
                    density: BrowserDensity.comfortable,
                    onTheme: (_) {},
                    onDensity: (_) {},
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      for (final label in [
        'System',
        'Light',
        'Dark',
        'Comfortable',
        'Compact',
      ]) {
        final tile = find.widgetWithText(ListTile, label);
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(tester.getSize(tile).height, greaterThanOrEqualTo(48));
        expect(tester.getSize(tile).width, greaterThanOrEqualTo(48));
        expect(tester.takeException(), isNull);
      }
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Close')).height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
    },
  );
}
