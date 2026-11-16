import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/android_update.dart';
import 'package:nntdrive/update_checks.dart';
import 'package:nntdrive/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final desktop = UpdateInfo(
    version: '9.0.0',
    notes: '',
    assetName: 'test',
    assetUrl: Uri.parse('https://example.invalid/test'),
    size: 0,
  );
  // The same scheduler drives Android; retain its distinct version-code deferral.
  for (final android in [false, true]) {
    group(android ? 'Android' : 'desktop', () {
      late SharedPreferences prefs;
      late AutomaticUpdateChecks<Object> runner;
      late Object offer;
      var checks = 0;
      var prompts = 0;
      var available = false;
      var failFeed = false;
      var failPrompt = false;
      var noUpdate = false;
      const old = '2020-01-01T00:00:00.000';
      setUp(() async {
        SharedPreferences.setMockInitialValues({'updateLastCheck': old});
        prefs = await SharedPreferences.getInstance();
        checks = prompts = 0;
        available = failFeed = failPrompt = noUpdate = false;
        offer = android ? 900 : desktop;
        runner = AutomaticUpdateChecks<Object>(
          check: () async {
            checks++;
            if (failFeed) throw StateError('offline');
            return noUpdate ? null : offer;
          },
          isSkipped: (info, prefs) async => android
              ? prefs.getInt(androidSkippedVersionCodeKey) == info
              : prefs.getString('updateSkippedVersion') ==
                  (info as UpdateInfo).version,
          prompt: (_) async {
            prompts++;
            if (failPrompt) throw StateError('no navigator');
            return available;
          },
        );
      });
      tearDown(() => runner.dispose());

      test(
          'swallowed onboarding prompt retains timestamp and retries on confirmation',
          () async {
        await runner.run(startup: true);
        expect(prompts, 1);
        expect(prefs.getString('updateLastCheck'), old);
        available = true;
        await runner.retryPending();
        expect(checks, 2);
        expect(prompts, 2);
        expect(prefs.getString('updateLastCheck'), isNot(old));
        await runner.retryPending();
        await runner.run();
        expect(checks, 2);
      });

      test('throwing prompt and feed failures never advance the daily gate',
          () async {
        failFeed = true;
        await runner.run(startup: true);
        expect(prefs.getString('updateLastCheck'), old);
        failFeed = false;
        failPrompt = true;
        await runner.run();
        expect(prefs.getString('updateLastCheck'), old);
        failPrompt = false;
        available = true;
        await runner.retryPending();
        expect(checks, 3);
        expect(prefs.getString('updateLastCheck'), isNot(old));
      });

      test('no-update success advances gate without a prompt', () async {
        noUpdate = true;
        await runner.run(startup: true);
        expect(prompts, 0);
        expect(prefs.getString('updateLastCheck'), isNot(old));
        await runner.retryPending();
        await runner.run();
        expect(checks, 1);
      });

      test('opt-out at confirmation preserves pending timestamp', () async {
        await runner.run(startup: true);
        await prefs.setBool('updateAutoCheck', false);
        available = true;
        await runner.retryPending();
        expect(checks, 1);
        expect(prompts, 1);
        expect(prefs.getString('updateLastCheck'), old);
      });

      test(
          'explicit skip/defer advances gate but never suppresses newer release',
          () async {
        if (android) {
          await prefs.setInt(androidSkippedVersionCodeKey, 900);
        } else {
          await prefs.setString('updateSkippedVersion', desktop.version);
        }
        await runner.run(startup: true);
        expect(prompts, 0);
        expect(prefs.getString('updateLastCheck'), isNot(old));
        offer = android
            ? 901
            : UpdateInfo(
                version: '9.0.1',
                notes: '',
                assetName: 'test',
                assetUrl: desktop.assetUrl,
                size: 0);
        available = true;
        await runner.run(startup: true);
        expect(checks, 2);
        expect(prompts, 1);
      });
    });
  }

  test('confirmation racing unavailable prompt is replayed once after the lock',
      () async {
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final result = Completer<bool>();
    var prompts = 0;
    final runner = UpdateChecks(
        check: () async => desktop,
        prompt: (_) {
          prompts++;
          if (prompts == 1) {
            entered.complete();
            return result.future;
          }
          return Future.value(true);
        });
    final first = runner.run(startup: true);
    await entered.future;
    await runner.retryPending();
    await runner.retryPending();
    result.complete(false);
    await first;
    expect(prompts, 2);
    expect((await SharedPreferences.getInstance()).getString('updateLastCheck'),
        isNotNull);
    runner.dispose();
  });

  test('confirmation racing a presented prompt does not duplicate it',
      () async {
    SharedPreferences.setMockInitialValues({});
    final entered = Completer<void>();
    final result = Completer<bool>();
    var prompts = 0;
    final runner = UpdateChecks(
        check: () async => desktop,
        prompt: (_) {
          prompts++;
          entered.complete();
          return result.future;
        });
    final first = runner.run(startup: true);
    await entered.future;
    await runner.retryPending();
    result.complete(true);
    await first;
    expect(prompts, 1);
    runner.dispose();
  });

  test(
      'disposed or opted-out in-flight feed cannot consume timestamp or prompt',
      () async {
    for (final dispose in [false, true]) {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final entered = Completer<void>();
      final result = Completer<UpdateInfo?>();
      var prompts = 0;
      final runner = UpdateChecks(check: () {
        entered.complete();
        return result.future;
      }, prompt: (_) async {
        prompts++;
        return true;
      });
      final first = runner.run(startup: true);
      await entered.future;
      if (dispose) {
        runner.dispose();
      } else {
        await prefs.setBool('updateAutoCheck', false);
      }
      result.complete(desktop);
      await first;
      expect(prompts, 0);
      expect(prefs.getString('updateLastCheck'), isNull);
      runner.dispose();
    }
  });
}
