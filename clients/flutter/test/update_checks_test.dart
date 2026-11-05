import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:nntdrive/update_checks.dart';
import 'package:nntdrive/updater.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final info = UpdateInfo(
      version: '9.0.0',
      notes: '',
      assetName: 'test',
      assetUrl: Uri.parse('https://example.invalid/test'),
      size: 0);

  test(
      'each launch checks despite recent timestamp; periodic checks stay daily',
      () async {
    SharedPreferences.setMockInitialValues(
        {'updateLastCheck': DateTime.now().toIso8601String()});
    var checks = 0;
    var prompts = 0;
    Future<UpdateInfo?> check() async {
      checks++;
      return info;
    }

    Future<void> prompt(UpdateInfo _) async {
      prompts++;
    }

    for (var launch = 0; launch < 2; launch++) {
      final runner = UpdateChecks(check: check, prompt: prompt);
      await runner.run(startup: true);
      await runner.run();
      runner.dispose();
    }
    expect(checks, 2);
    expect(prompts, 2);
  });

  test('deferred version suppresses prompts, not checks; newer version prompts',
      () async {
    SharedPreferences.setMockInitialValues({'updateSkippedVersion': '9.0.0'});
    var checks = 0;
    var prompts = 0;
    var version = info;
    final runner = UpdateChecks(check: () async {
      checks++;
      return version;
    }, prompt: (_) async {
      prompts++;
    });
    await runner.run(startup: true);
    version = UpdateInfo(
        version: '10.0.0',
        notes: '',
        assetName: 'test',
        assetUrl: info.assetUrl,
        size: 0);
    await runner.run(startup: true);
    expect(checks, 2);
    expect(prompts, 1);
    runner.dispose();
  });

  test('opt-out disables automatic checks and offline failures are harmless',
      () async {
    SharedPreferences.setMockInitialValues({'updateAutoCheck': false});
    var checks = 0;
    final runner = UpdateChecks(
        check: () async {
          checks++;
          throw Exception('offline');
        },
        prompt: (_) async {});
    await runner.run(startup: true);
    expect(checks, 0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('updateAutoCheck', true);
    await runner.run(startup: true);
    await runner.run(startup: true);
    expect(checks, 2);
    runner.dispose();
  });

  testWidgets('start schedules daily checks once and dispose cancels them',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    var checks = 0;
    final runner = UpdateChecks(
        check: () async {
          checks++;
          return null;
        },
        prompt: (_) async {});
    runner.start();
    runner.start();
    await tester.pump();
    expect(checks, 1);
    await tester.pump(const Duration(hours: 23));
    expect(checks, 1);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('updateLastCheck');
    await tester.pump(const Duration(hours: 1));
    expect(checks, 2);
    runner.dispose();
    await tester.pump(const Duration(days: 2));
    expect(checks, 2);
  });

  test('manual and automatic flows share the lock through prompt dismissal',
      () async {
    SharedPreferences.setMockInitialValues({});
    final done = Completer<void>();
    var checks = 0;
    final runner = UpdateChecks(
        check: () async {
          checks++;
          return null;
        },
        prompt: (_) async {});
    final manual = runner.manual(() => done.future);
    await runner.run(startup: true);
    var duplicate = false;
    await runner.manual(() async {
      duplicate = true;
    });
    expect(checks, 0);
    expect(duplicate, false);
    done.complete();
    await manual;
    await runner.run(startup: true);
    expect(checks, 1);
    runner.dispose();
  });

  test(
      'overlapping checks and open prompts are guarded; disposal prevents prompts',
      () async {
    SharedPreferences.setMockInitialValues({});
    var checks = 0;
    var prompts = 0;
    final response = Completer<UpdateInfo?>();
    final dismissed = Completer<void>();
    final runner = UpdateChecks(check: () {
      checks++;
      return response.future;
    }, prompt: (_) {
      prompts++;
      return dismissed.future;
    });
    final pending = runner.run(startup: true);
    await Future<void>.delayed(Duration.zero);
    await runner.run(startup: true);
    response.complete(info);
    await Future<void>.delayed(Duration.zero);
    await runner.run(startup: true);
    expect(checks, 1);
    expect(prompts, 1);
    dismissed.complete();
    await pending;
    runner.dispose();
    await runner.run(startup: true);
    expect(checks, 1);
  });
}
