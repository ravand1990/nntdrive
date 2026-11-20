import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/main.dart';
import 'package:nntdrive/secure_keyfile.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> values = {};
  final List<String> events = [];
  final List<String> fallbacks = [];
  bool failRead = false;
  bool failWrite = false;
  bool failDelete = false;
  bool tamperWrite = false;
  bool hangRead = false;

  @override
  String get label => 'Fake keyring';

  @override
  Future<String?> read(String key) async {
    events.add('read');
    if (failRead) throw CredentialStoreUnavailable('not reachable');
    if (hangRead) await Completer<String?>().future;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    events.add('write');
    if (failWrite) throw CredentialStoreUnavailable('write denied');
    values[key] = tamperWrite ? 'tampered' : value;
  }

  @override
  Future<void> delete(String key) async {
    events.add('delete');
    if (failDelete) throw CredentialStoreUnavailable('delete denied');
    values.remove(key);
  }

  @override
  Future<void> close() async => events.add('close');
}

Future<SharedPreferences> prefsWith(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

KeyfileVault vaultWith(FakeCredentialStore store, SharedPreferences prefs) {
  final vault = KeyfileVault(store: store, prefs: prefs);
  return vault;
}

void main() {
  test('migrates the remembered keyfile out of preferences', () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore();
    final vault = vaultWith(store, prefs);

    expect(await vault.load(), 'wrapped-1');
    expect(store.values['keyfile'], 'wrapped-1');
    expect(prefs.getString('keyfile'), isNull);
    // Write and verify happen before the old copy is deleted.
    expect(store.events, ['read', 'write', 'read']);
  });

  test('a rejected migration keeps the preferences copy and still unlocks',
      () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore()..failWrite = true;
    final reasons = <String>[];
    final vault = KeyfileVault(
        store: store, prefs: prefs, onFallback: reasons.add);

    expect(await vault.load(), 'wrapped-1');
    expect(prefs.getString('keyfile'), 'wrapped-1');
    expect(store.values, isEmpty);
    expect(reasons, isNotEmpty);
    // Diagnostics name the store, never the stored value.
    expect(reasons.join(' '), isNot(contains('wrapped-1')));
    expect(reasons.join(' '), contains('Fake keyring'));
  });

  test('a store that silently changes the value does not delete the old copy',
      () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore()..tamperWrite = true;
    final vault = vaultWith(store, prefs);

    expect(await vault.load(), 'wrapped-1');
    expect(prefs.getString('keyfile'), 'wrapped-1');
  });

  test('prefers the credential store and drops a stale preferences copy',
      () async {
    final prefs = await prefsWith({'keyfile': 'stale'});
    final store = FakeCredentialStore()..values['keyfile'] = 'fresh';
    final vault = vaultWith(store, prefs);

    expect(await vault.load(), 'fresh');
    expect(prefs.getString('keyfile'), isNull);
    expect(store.events, ['read']);
  });

  test('saves into the credential store and not into preferences', () async {
    final prefs = await prefsWith({});
    final store = FakeCredentialStore();
    final vault = vaultWith(store, prefs);

    await vault.save('wrapped-2');

    expect(store.values['keyfile'], 'wrapped-2');
    expect(prefs.getString('keyfile'), isNull);
  });

  test('saving falls back to preferences when the store rejects the write',
      () async {
    final prefs = await prefsWith({});
    final store = FakeCredentialStore()..failWrite = true;
    final reasons = <String>[];
    final vault = KeyfileVault(
        store: store, prefs: prefs, onFallback: reasons.add);

    await vault.save('wrapped-2');

    expect(prefs.getString('keyfile'), 'wrapped-2');
    expect(reasons.join(' '), isNot(contains('wrapped-2')));
  });

  test('clear removes the keyfile from both locations', () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore()..values['keyfile'] = 'wrapped-1';
    final vault = vaultWith(store, prefs);

    await vault.clear();

    expect(store.values, isEmpty);
    expect(prefs.getString('keyfile'), isNull);
  });

  test('sign-out still clears preferences when the store delete fails',
      () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore()
      ..values['keyfile'] = 'wrapped-1'
      ..failDelete = true;
    final vault = vaultWith(store, prefs);

    await vault.clear();

    expect(prefs.getString('keyfile'), isNull);
  });

  test('read failures fall back to the preferences copy', () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore()..failRead = true;
    final reasons = <String>[];
    final vault = KeyfileVault(
        store: store, prefs: prefs, onFallback: reasons.add);

    expect(await vault.load(), 'wrapped-1');
    expect(prefs.getString('keyfile'), 'wrapped-1');
    expect(reasons.join(' '), contains('not reachable'));
  });

  test('an unresponsive store falls back instead of stalling', () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final store = FakeCredentialStore()..hangRead = true;
    final vault = KeyfileVault(
      store: store,
      prefs: prefs,
      operationTimeout: const Duration(milliseconds: 20),
    );

    expect(await vault.load(), 'wrapped-1');
    expect(prefs.getString('keyfile'), 'wrapped-1');
  });

  test('without a credential store behaviour is unchanged', () async {
    final prefs = await prefsWith({'keyfile': 'wrapped-1'});
    final vault = KeyfileVault(prefs: prefs);
    expect(vault.usesCredentialStore, isFalse);
    expect(await vault.load(), 'wrapped-1');

    await vault.save('wrapped-2');
    expect(prefs.getString('keyfile'), 'wrapped-2');

    await vault.clear();
    expect(prefs.getString('keyfile'), isNull);
  });

  test('nothing stored anywhere loads as null', () async {
    final prefs = await prefsWith({});
    final vault = vaultWith(FakeCredentialStore(), prefs);
    expect(await vault.load(), isNull);
  });

  test('windows credential target names stay scoped to the app', () {
    expect(WindowsCredentialStore.targetName('keyfile'), 'NNTDrive:keyfile');
  });

  testWidgets('the app migrates the remembered keyfile on start',
      (tester) async {
    final prefs = await prefsWith({
      'server': 'http://127.0.0.1:8080',
      'keyfile': '{"wrapped":true}',
      'accountId': 'account-1',
      'email': 'test@example.invalid',
      'updateAutoCheck': false,
    });
    final store = FakeCredentialStore();
    final vault = KeyfileVault(store: store, prefs: prefs);

    await tester.pumpWidget(NntDriveApp(prefs: prefs, keyfileVault: vault));
    await tester.pumpAndSettle();

    expect(store.values['keyfile'], '{"wrapped":true}');
    expect(prefs.getString('keyfile'), isNull);
  });
}
