import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/secure_keyfile.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for the Kotlin Keystore channel: keeps ciphertext "at rest" only,
/// so the test can prove Dart never keeps the value anywhere else.
class FakeKeystoreChannel {
  final Map<String, String> stored = {};
  final List<String> events = [];
  Object? failure;
  bool hang = false;
  String? replaceWith;

  late final MethodChannel channel =
      const MethodChannel(AndroidKeyStoreStore.channelName);

  void install(TestDefaultBinaryMessengerBinding binding) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      events.add('${call.method}:${(call.arguments as Map)['key']}');
      if (hang) await Completer<void>().future;
      final failure = this.failure;
      if (failure != null) throw failure;
      final key = (call.arguments as Map)['key'] as String;
      switch (call.method) {
        case 'read':
          return stored[key];
        case 'write':
          stored[key] = replaceWith ?? (call.arguments as Map)['value'] as String;
          return true;
        case 'delete':
          stored.remove(key);
          return true;
      }
      throw MissingPluginException('unsupported ${call.method}');
    });
  }

  void remove(TestDefaultBinaryMessengerBinding binding) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final binding = TestDefaultBinaryMessengerBinding.instance;

  late FakeKeystoreChannel fake;

  setUp(() {
    fake = FakeKeystoreChannel()..install(binding);
  });

  tearDown(() {
    fake.remove(binding);
  });

  test('round trips a value through the channel', () async {
    final store = AndroidKeyStoreStore();
    expect(await store.read('keyfile'), isNull);

    await store.write('keyfile', '{"wrapped":"value"}');
    expect(await store.read('keyfile'), '{"wrapped":"value"}');
    expect(fake.events, [
      'read:keyfile',
      'write:keyfile',
      'read:keyfile',
    ]);

    await store.delete('keyfile');
    expect(await store.read('keyfile'), isNull);
    expect(store.label, 'Android Keystore');
  });

  test('an empty stored value counts as absent', () async {
    final store = AndroidKeyStoreStore();
    await store.write('keyfile', '');
    expect(await store.read('keyfile'), isNull);
  });

  test('a platform error becomes an unavailable store, without the value', () async {
    final store = AndroidKeyStoreStore();
    fake.failure = PlatformException(code: 'unavailable', message: 'keystore');

    await expectLater(
      store.read('keyfile'),
      throwsA(isA<CredentialStoreUnavailable>().having(
        (error) => error.reason,
        'reason',
        contains('unavailable'),
      )),
    );
    expect(fake.events, ['read:keyfile']);
  });

  test('a missing channel becomes an unavailable store', () async {
    final store = AndroidKeyStoreStore();
    fake.remove(binding);
    await expectLater(
        store.read('keyfile'), throwsA(isA<CredentialStoreUnavailable>()));
  });

  test('a hung Keystore call times out instead of stalling startup', () async {
    final store = AndroidKeyStoreStore(timeout: const Duration(milliseconds: 30));
    fake.hang = true;
    await expectLater(
        store.read('keyfile'), throwsA(isA<CredentialStoreUnavailable>()));
  });

  test('the vault migrates the keyfile out of preferences on Android', () async {
    SharedPreferences.setMockInitialValues({'keyfile': 'wrapped-legacy'});
    final prefs = await SharedPreferences.getInstance();
    final vault = KeyfileVault(store: AndroidKeyStoreStore(), prefs: prefs);

    expect(await vault.load(), 'wrapped-legacy');
    expect(fake.stored['keyfile'], 'wrapped-legacy');
    expect(prefs.getString('keyfile'), isNull);
    // Write and read-back happen before the preferences copy is dropped.
    expect(fake.events, ['read:keyfile', 'write:keyfile', 'read:keyfile']);
  });

  test('a rejected write keeps the preferences copy and still unlocks', () async {
    SharedPreferences.setMockInitialValues({'keyfile': 'wrapped-legacy'});
    final prefs = await SharedPreferences.getInstance();
    final vault = KeyfileVault(store: AndroidKeyStoreStore(), prefs: prefs);
    fake.failure = PlatformException(code: 'unavailable');

    expect(await vault.load(), 'wrapped-legacy');
    expect(prefs.getString('keyfile'), 'wrapped-legacy');
    expect(fake.stored, isEmpty);
  });

  test('a store that keeps the wrong value falls back to preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final vault = KeyfileVault(store: AndroidKeyStoreStore(), prefs: prefs);
    fake.replaceWith = 'tampered';

    await vault.save('wrapped-new');
    expect(prefs.getString('keyfile'), 'wrapped-new');
  });
}
