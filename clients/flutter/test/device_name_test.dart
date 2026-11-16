import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/device_name.dart';
import 'package:nntdrive/device_onboarding.dart';

void main() {
  test('platform suggestions prefer recognisable local values', () {
    expect(
      deviceNameDefault(
        platform: 'android',
        displayName: 'My phone',
        model: 'Example Model',
      ),
      'My phone',
    );
    expect(
      deviceNameDefault(
        platform: 'android',
        displayName: 'localhost',
        model: 'Example Model',
      ),
      'Example Model',
    );
    expect(
      deviceNameDefault(
        platform: 'windows',
        computerName: 'OFFICE-PC',
        hostname: 'localhost',
      ),
      'OFFICE-PC',
    );
    expect(
      deviceNameDefault(platform: 'linux', hostname: 'work-laptop'),
      'work-laptop',
    );
    for (final bad in [
      '',
      'localhost',
      'localhost.localdomain',
      'a4b65fcd1234',
      'NUL',
      'wrong/name',
      'a' * 65,
    ]) {
      expect(
        deviceNameDefault(platform: 'linux', hostname: bad),
        'My Linux device',
      );
    }
    expect(deviceNameDefault(platform: 'android'), 'My Android device');
    expect(deviceNameDefault(platform: 'windows'), 'My Windows device');
  });

  test(
    'device names enforce portable printable Unicode and character bounds',
    () {
      for (final bad in [
        '',
        'x' * 65,
        '.',
        '..',
        'NUL .txt',
        'COM¹',
        'LPT³.log',
        'a/b',
        r'a\b',
        'x.',
        'x ',
        ' x',
        'x\n',
        'x\u0085',
        'hidden\u202e',
        'hidden\u200b',
        'x\uffff',
        String.fromCharCode(0xd800),
        String.fromCharCode(0xdc00),
      ]) {
        expect(deviceNameValidationError(bad), isNotNull);
      }
      for (final valid in [
        'x',
        'x' * 64,
        'Café laptop',
        'Cafe\u0301',
        'Phone 😀',
        'COM10',
        'Family �',
      ]) {
        expect(deviceNameValidationError(valid), isNull);
      }
    },
  );

  test(
    'confirmation is scoped to server, account, device and immutable root',
    () {
      final key = deviceConfirmationKey('https://one', 'a', 'd', 'r');
      expect(key, isNot(deviceConfirmationKey('https://two', 'a', 'd', 'r')));
      expect(key, isNot(deviceConfirmationKey('https://one', 'b', 'd', 'r')));
      expect(key, isNot(deviceConfirmationKey('https://one', 'a', 'e', 'r')));
      expect(key, isNot(deviceConfirmationKey('https://one', 'a', 'd', 's')));
    },
  );

  testWidgets('Android channel is read only and model is a fallback', (
    tester,
  ) async {
    const channel = MethodChannel('dev.nntdrive/device_name');
    // Exercise the exact platform contract even when this test runs on Linux.
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call.method);
      return {'name': '', 'model': 'Example Phone'};
    });
    final result = await channel.invokeMapMethod<String, String>('read');
    expect(
      deviceNameDefault(
        platform: 'android',
        displayName: result?['name'],
        model: result?['model'],
      ),
      'Example Phone',
    );
    expect(calls, ['read']);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });
}
