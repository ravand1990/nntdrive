import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/login_autostart.dart';
import 'package:nntdrive/login_autostart_settings.dart';
import 'package:nntdrive/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeLoginAutostart implements LoginAutostart {
  @override
  bool supported = true;
  bool enabled = false;
  bool fail = false;
  final choices = <bool>[];
  Completer<void>? gate;
  @override
  Future<bool> isEnabled() async => enabled;
  @override
  Future<void> apply({
    required bool enabled,
    required String executable,
  }) async {
    choices.add(enabled);
    await gate?.future;
    if (fail) throw StateError('private OS diagnostic');
    this.enabled = enabled;
  }
}

void main() {
  Future<SharedPreferences> prefs([
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues({
      'updateAutoCheck': false,
      ...values,
    });
    return SharedPreferences.getInstance();
  }

  test(
    'denied Windows deletion and read-back never persist disabled state',
    () async {
      final preferences = await prefs({loginAutostartPreferenceKey: true});
      final registration = WindowsLoginAutostart(
        runProcess: (_, __) async =>
            ProcessResult(1, 1, '', 'Access is denied.'),
      );
      final settings = LoginAutostartSettings(
        prefs: preferences,
        registration: registration,
        executable: r'C:\Apps\nntdrive.exe',
      );
      expect(await settings.setEnabled(false), isNotNull);
      expect(preferences.getBool(loginAutostartPreferenceKey), isTrue);
      expect(settings.error, isNotNull);
      settings.dispose();
    },
  );

  test(
    'reads current OS state and serializes changes before persisting',
    () async {
      final preferences = await prefs();
      final registration = FakeLoginAutostart()..enabled = true;
      final settings = LoginAutostartSettings(
        prefs: preferences,
        registration: registration,
        executable: '/updated/nntdrive',
      );
      await settings.initialize();
      expect(settings.enabled, isTrue);
      expect(registration.choices, isEmpty);
      registration.gate = Completer<void>();
      final off = settings.setEnabled(false);
      expect(settings.busy, isTrue);
      expect(await settings.setEnabled(true), contains('busy'));
      expect(preferences.getBool(loginAutostartPreferenceKey), isNull);
      registration.gate!.complete();
      expect(await off, isNull);
      expect(settings.enabled, isFalse);
      expect(registration.choices, [false]);
      expect(preferences.getBool(loginAutostartPreferenceKey), isFalse);
      settings.dispose();
    },
  );

  testWidgets('two views share the same live state', (tester) async {
    final settings = LoginAutostartSettings(
      prefs: await prefs(),
      registration: FakeLoginAutostart(),
      executable: '/nntdrive',
    );
    await settings.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              LoginAutostartControl(settings: settings),
              LoginAutostartControl(settings: settings),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byType(SwitchListTile).first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widgetList<SwitchListTile>(find.byType(SwitchListTile))
          .every((control) => control.value),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets(
    'fresh login offers immediate persisted opt-in without account data',
    (tester) async {
      final preferences = await prefs();
      final registration = FakeLoginAutostart();
      await tester.pumpWidget(
        NntDriveApp(prefs: preferences, loginAutostart: registration),
      );
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsOneWidget);
      expect(find.text('Start NNTDrive when I sign in'), findsOneWidget);
      await tester.ensureVisible(find.byType(SwitchListTile));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(registration.choices, [true]);
      expect(preferences.getBool(loginAutostartPreferenceKey), isTrue);
      expect(
        preferences.getKeys(),
        unorderedEquals(['updateAutoCheck', loginAutostartPreferenceKey]),
      );
      expect(find.byType(FilesPage), findsNothing);
      expect(find.textContaining('locked. Your password'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        NntDriveApp(prefs: preferences, loginAutostart: registration),
      );
      await tester.pumpAndSettle();
      expect(registration.choices, [true, true]); // repairs remembered binary
      expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        isTrue,
      );
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      expect(preferences.getBool(loginAutostartPreferenceKey), isFalse);
      expect(registration.enabled, isFalse);
    },
  );

  testWidgets('unlock shares the option and signing out preserves it', (
    tester,
  ) async {
    final preferences = await prefs({
      'token': 'fixture',
      'keyfile': '{}',
      'accountId': 'fixture',
      'email': 'fixture@example.invalid',
    });
    final registration = FakeLoginAutostart();
    await tester.pumpWidget(
      NntDriveApp(prefs: preferences, loginAutostart: registration),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UnlockPage), findsOneWidget);
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(registration.enabled, isTrue);
    await tester.tap(find.text('Use another account / server'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    expect(preferences.getBool(loginAutostartPreferenceKey), isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.byType(FilesPage), findsNothing);
  });

  testWidgets('unsupported platform explains disabled control', (tester) async {
    final registration = FakeLoginAutostart()..supported = false;
    await tester.pumpWidget(
      NntDriveApp(prefs: await prefs(), loginAutostart: registration),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(
      find.text('Login startup is available on Windows and Linux only.'),
      findsOneWidget,
    );
    expect(registration.choices, isEmpty);
  });

  testWidgets('pre-login registration failure is inline and retryable', (
    tester,
  ) async {
    final preferences = await prefs();
    final registration = FakeLoginAutostart()..fail = true;
    await tester.pumpWidget(
      NntDriveApp(prefs: preferences, loginAutostart: registration),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(preferences.getBool(loginAutostartPreferenceKey), isNull);
    expect(
      find.textContaining('Could not save login startup.'),
      findsOneWidget,
    );
    expect(find.textContaining('private OS diagnostic'), findsNothing);
    registration.fail = false;
    await tester.ensureVisible(find.text('Retry login startup'));
    await tester.tap(find.text('Retry login startup'));
    await tester.pumpAndSettle();
    expect(registration.choices, [true, true]);
    expect(preferences.getBool(loginAutostartPreferenceKey), isTrue);
    expect(find.text('Retry login startup'), findsNothing);
  });
}
