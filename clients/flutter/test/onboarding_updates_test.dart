import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/android_update.dart';
import 'package:nntdrive/device_onboarding.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_widget_test.dart' show SessionApi;

Future<void> until(WidgetTester tester, bool Function() ready) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 150 && !ready(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump();
    }
  });
  expect(ready(), isTrue,
      reason: 'app lifecycle did not reach the expected UI');
  await tester.pumpAndSettle();
}

void main() {
  final desktopOffer = UpdateInfo(
      version: '9.0.0',
      notes: '',
      assetName: 'test',
      assetUrl: Uri.parse('https://example.invalid/test'),
      size: 0);
  final androidOffer = AndroidUpdateInfo(
      version: '9.0.0',
      versionCode: 900,
      notes: '',
      assetName: 'test.apk',
      assetUrl: desktopOffer.assetUrl,
      size: 0,
      sha256: '0' * 64);

  for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
    for (final retry in [false, true]) {
      testWidgets(
          '${platform.name}: ${retry ? 'failed startup retries after confirmation' : 'prompt over naming, Later keeps edited name usable'}',
          (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        const password = 'update lifecycle test password';
        final account = (await tester.runAsync(
            () => NativeBridge.instance.generateAccountAsync(password)))!;
        final keyfile = jsonEncode(account['keyfile']);
        SharedPreferences.setMockInitialValues({
          'token': 'fixture-token',
          'keyfile': keyfile,
          'accountId': account['account_id'],
          'email': 'test@example.invalid',
          'server': 'http://127.0.0.1:1',
        });
        final prefs = await SharedPreferences.getInstance();
        final setupHandle =
            NativeBridge.instance.unlock(keyfile, password)['handle'] as int;
        final api = SessionApi(
            account['account_id'] as String,
            NativeBridge.instance
                .sealName(setupHandle, SessionApi.node, 'Device'));
        NativeBridge.instance.lock(setupHandle);
        final feedReady = Completer<void>();
        var checks = 0;
        Future<void> feed() async {
          checks++;
          if (retry && checks == 1) throw StateError('feed unavailable');
          if (!retry) await feedReady.future;
        }

        await tester.pumpWidget(NntDriveApp(
          prefs: prefs,
          apiFactory: (_, __) => api,
          updateCheck: () async {
            await feed();
            return desktopOffer;
          },
          androidUpdateCheck: () async {
            await feed();
            return androidOffer;
          },
        ));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), password);
        await tester.tap(find.widgetWithText(FilledButton, 'Unlock'));
        await until(
            tester,
            () =>
                find.byType(DeviceOnboardingPage).evaluate().isNotEmpty &&
                tester
                    .widgetList<TextField>(find.byType(TextField))
                    .any((field) => field.enabled != false));
        expect(checks, 1);
        expect(prefs.getString('updateLastCheck'), isNull);
        await tester.enterText(find.byType(TextField), 'My updated laptop');
        if (!retry) {
          feedReady.complete();
          await until(
              tester,
              () =>
                  find.text('Update available — 9.0.0').evaluate().isNotEmpty);
          expect(find.byType(DeviceOnboardingPage), findsOneWidget);
          // A still-open dialog has not acknowledged presentation to the scheduler.
          expect(prefs.getString('updateLastCheck'), isNull);
          await tester.tap(find.text('Later'));
          await tester.pumpAndSettle();
          expect(
              tester.widget<TextField>(find.byType(TextField)).controller!.text,
              'My updated laptop');
        }
        await tester.runAsync(() async {
          await tester
              .tap(find.widgetWithText(FilledButton, 'Confirm device name'));
        });
        await until(
            tester,
            () =>
                find.byType(FilesPage).evaluate().isNotEmpty &&
                (retry
                    ? find
                        .text('Update available — 9.0.0')
                        .evaluate()
                        .isNotEmpty
                    : find
                        .byType(CircularProgressIndicator)
                        .evaluate()
                        .isEmpty));
        if (retry) {
          expect(checks, 2);
          expect(prefs.getString('updateLastCheck'), isNull);
          await tester.tap(find.text('Later'));
          await tester.pumpAndSettle();
        } else {
          expect(checks, 1,
              reason:
                  'confirmed onboarding must not duplicate acknowledged offers');
        }
        await until(tester, () => prefs.getString('updateLastCheck') != null);
        expect(
            platform == TargetPlatform.android
                ? prefs.getInt(androidSkippedVersionCodeKey) == 900
                : prefs.getString('updateSkippedVersion') == '9.0.0',
            isTrue);
        final files = tester.widget<FilesPage>(find.byType(FilesPage));
        expect(files.updates,
            isNotNull); // Existing manual check owner is retained.
        files.onSignOut();
        await until(tester, () => find.byType(FilesPage).evaluate().isEmpty);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
        debugDefaultTargetPlatformOverride = null;
      });
    }
  }
}
