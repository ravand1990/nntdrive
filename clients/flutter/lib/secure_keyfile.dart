import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:ffi/ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A key/value store backed by an operating-system credential store.
///
/// Implementations must never write the value anywhere except the platform
/// store they wrap, and must throw (rather than silently succeed) when the
/// store is unavailable or locked.
abstract class CredentialStore {
  /// Name of the backend, used in diagnostics that never include values.
  String get label;

  /// Returns the stored value, or null when nothing is stored for [key].
  Future<String?> read(String key);

  /// Stores [value] under [key], replacing an existing entry.
  Future<void> write(String key, String value);

  /// Removes the entry for [key]; missing entries are not an error.
  Future<void> delete(String key);

  /// Releases platform resources such as a D-Bus connection.
  Future<void> close();
}

/// Where the password-wrapped keyfile is kept.
///
/// The preferred location is an OS credential store (Linux Secret Service or
/// Windows Credential Manager). Installs that migrated from an older client
/// still have the wrapped keyfile in shared preferences; [load] moves it once,
/// writing the new copy before deleting the old one so an interrupted
/// migration can only leave a duplicate, never lose the login.
///
/// When no credential store is available (Android, macOS/iOS until their
/// backends land, a locked or missing Linux keyring, or a headless session)
/// the wrapped keyfile stays in shared preferences exactly as before. The
/// value is already password-wrapped, so this is the pre-existing exposure,
/// not plaintext key material.
class KeyfileVault {
  KeyfileVault({
    CredentialStore? store,
    required SharedPreferences prefs,
    this.legacyKey = 'keyfile',
    this.credentialKey = 'keyfile',
    this.onFallback,
    this.operationTimeout = defaultOperationTimeout,
  })  : _store = store,
        _prefs = prefs;

  /// A locked or unresponsive keyring must not stall sign-in or startup: after
  /// this bound the wrapped-keyfile copy in preferences is used instead.
  static const defaultOperationTimeout = Duration(seconds: 4);

  final Duration operationTimeout;

  final CredentialStore? _store;
  final SharedPreferences _prefs;

  /// Shared-preferences entry used by older clients; removed after migration.
  final String legacyKey;

  /// Entry name inside the credential store.
  final String credentialKey;

  /// Called with a short, value-free reason when the credential store could
  /// not be used. Never includes keyfile contents.
  final void Function(String reason)? onFallback;

  bool get usesCredentialStore => _store != null;

  /// Loads the wrapped keyfile, migrating it out of preferences when possible.
  Future<String?> load() async {
    final store = _store;
    if (store != null) {
      String? stored;
      try {
        stored = await store.read(credentialKey).timeout(operationTimeout);
      } catch (error) {
        _fallback('${store.label} is unavailable: ${_describe(error)}');
      }
      if (stored != null && stored.isNotEmpty) {
        // A stale preferences copy after a completed migration is only a
        // duplicate of the wrapped keyfile; drop it.
        if (_prefs.containsKey(legacyKey)) {
          try {
            await _prefs.remove(legacyKey);
          } catch (_) {
            // Keeping a duplicate copy is not a correctness problem.
          }
        }
        return stored;
      }
      final legacy = _prefs.getString(legacyKey);
      if (legacy == null || legacy.isEmpty) return null;
      // A failed migration keeps the preferences copy, which is what we return.
      await _migrate(store, legacy);
      return legacy;
    }
    final legacy = _prefs.getString(legacyKey);
    return (legacy == null || legacy.isEmpty) ? null : legacy;
  }

  /// Persists [keyfileJson] in the credential store, or in preferences when no
  /// credential store can accept it.
  Future<void> save(String keyfileJson) async {
    final store = _store;
    if (store != null) {
      try {
        await store.write(credentialKey, keyfileJson).timeout(operationTimeout);
        final readBack =
            await store.read(credentialKey).timeout(operationTimeout);
        if (readBack != keyfileJson) {
          throw StateError('credential store did not keep the written value');
        }
        if (_prefs.containsKey(legacyKey)) await _prefs.remove(legacyKey);
        return;
      } catch (error) {
        _fallback('${store.label} rejected the keyfile: ${_describe(error)}');
      }
    }
    await _prefs.setString(legacyKey, keyfileJson);
  }

  /// Removes the wrapped keyfile from every location it may occupy.
  Future<void> clear() async {
    final store = _store;
    if (store != null) {
      try {
        await store.delete(credentialKey).timeout(operationTimeout);
      } catch (error) {
        // Sign-out must still clear the preferences copy; a stale credential
        // store entry is retried on the next sign-out.
        _fallback('${store.label} could not be cleared: ${_describe(error)}');
      }
    }
    await _prefs.remove(legacyKey);
  }

  /// Copies a legacy preferences value into [store].
  ///
  /// The order matters: write and verify, then delete. An interrupted run
  /// leaves the old copy in place, and the next start retries.
  Future<bool> _migrate(CredentialStore store, String legacy) async {
    try {
      await store.write(credentialKey, legacy).timeout(operationTimeout);
      final readBack =
          await store.read(credentialKey).timeout(operationTimeout);
      if (readBack != legacy) {
        throw StateError('credential store did not keep the migrated value');
      }
    } catch (error) {
      _fallback('migration to ${store.label} failed: ${_describe(error)}');
      return false;
    }
    try {
      await _prefs.remove(legacyKey);
    } catch (error) {
      // The credential store now holds the authoritative copy; keeping the old
      // one duplicates a wrapped keyfile without breaking login.
      _fallback('old keyfile copy could not be removed: ${_describe(error)}');
    }
    return true;
  }

  void _fallback(String reason) => onFallback?.call(reason);

  /// Releases the credential-store connection, if there is one.
  Future<void> dispose() async {
    final store = _store;
    if (store == null) return;
    try {
      await store.close().timeout(operationTimeout);
    } catch (_) {
      // Closing a store that already failed is not an error worth surfacing.
    }
  }

  static String _describe(Object error) {
    // Report the type only: platform errors can embed paths or values.
    if (error is CredentialStoreUnavailable) return error.reason;
    return error.runtimeType.toString();
  }
}

/// Raised when a platform credential store cannot serve a request.
class CredentialStoreUnavailable implements Exception {
  CredentialStoreUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'CredentialStoreUnavailable: $reason';
}

/// Returns the credential store for this platform, or null when the platform
/// has no backend yet or cannot provide one right now.
CredentialStore? createPlatformCredentialStore() {
  try {
    if (Platform.isLinux) {
      // Without a session bus there is no Secret Service to talk to; asking
      // would only stall startup before falling back anyway.
      final bus = Platform.environment['DBUS_SESSION_BUS_ADDRESS'];
      if (bus == null || bus.isEmpty) return null;
      return LinuxSecretServiceStore();
    }
    if (Platform.isWindows) return WindowsCredentialStore();
  } catch (_) {
    // A missing session bus or advapi32 entry point is a fallback, not a
    // startup failure: the caller keeps using shared preferences.
    return null;
  }
  return null;
}

/// Linux Secret Service (`org.freedesktop.secrets`), the API behind
/// GNOME Keyring, KWallet and KeePassXC's secret-service bridge.
class LinuxSecretServiceStore implements CredentialStore {
  LinuxSecretServiceStore({
    DBusClient? client,
    this.timeout = const Duration(seconds: 5),
    this.collectionPath,
  }) : _client = client ?? DBusClient.session();

  static const _serviceName = 'org.freedesktop.secrets';
  static const _serviceInterface = 'org.freedesktop.Secret.Service';
  static const _collectionInterface = 'org.freedesktop.Secret.Collection';
  static const _itemInterface = 'org.freedesktop.Secret.Item';
  static final _servicePath = DBusObjectPath('/org/freedesktop/secrets');
  static final _rootPath = DBusObjectPath('/');

  final DBusClient _client;
  final Duration timeout;

  /// Overrides discovery of the default collection (tests).
  final DBusObjectPath? collectionPath;

  DBusObjectPath? _session;

  @override
  String get label => 'Linux Secret Service';

  DBusRemoteObject get _service => DBusRemoteObject(
        _client,
        name: _serviceName,
        path: _servicePath,
      );

  Future<DBusObjectPath> _openSession() {
    final existing = _session;
    if (existing != null) return Future.value(existing);
    return () async {
      final response = await _service
          .callMethod(_serviceInterface, 'OpenSession', [
            const DBusString('plain'),
            const DBusVariant(DBusString('')),
          ])
          .timeout(timeout);
      final session = response.returnValues[1].asObjectPath();
      if (session == _rootPath) {
        throw CredentialStoreUnavailable('Secret Service refused a session');
      }
      _session = session;
      return session;
    }();
  }

  Future<DBusObjectPath> _collection() async {
    final override = collectionPath;
    if (override != null) return override;
    final response = await _service
        .callMethod(_serviceInterface, 'ReadAlias', [const DBusString('default')])
        .timeout(timeout);
    final collection = response.returnValues[0].asObjectPath();
    if (collection != _rootPath) return collection;
    throw CredentialStoreUnavailable('no default Secret Service collection');
  }

  DBusDict _attributes(String key) => DBusDict.stringVariant({
        'application': const DBusString('nntdrive'),
        'purpose': DBusString(key),
      });

  @override
  Future<String?> read(String key) async {
    final session = await _openSession();
    final response = await _service
        .callMethod(_serviceInterface, 'SearchItems', [_attributes(key)])
        .timeout(timeout);
    final unlocked = response.returnValues[0].asArray();
    final locked = response.returnValues[1].asArray();
    var items = unlocked;
    if (items.isEmpty && locked.isNotEmpty) {
      final unlock = await _service
          .callMethod(_serviceInterface, 'Unlock', [
            DBusArray(DBusSignature('o'), locked),
          ])
          .timeout(timeout);
      if (unlock.returnValues[1].asObjectPath() != _rootPath) {
        throw CredentialStoreUnavailable('keyring is locked');
      }
      items = unlock.returnValues[0].asArray();
    }
    if (items.isEmpty) return null;
    final item = DBusRemoteObject(
      _client,
      name: _serviceName,
      path: items.first.asObjectPath(),
    );
    final secret = await item
        .callMethod(_itemInterface, 'GetSecret', [session])
        .timeout(timeout);
    final parts = secret.returnValues[0].asStruct();
    final bytes = parts[2].asArray().map((value) => value.asByte()).toList();
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> write(String key, String value) async {
    final session = await _openSession();
    final collection = await _collection();
    final secret = DBusStruct([
      session,
      DBusArray.byte(const <int>[]),
      DBusArray.byte(utf8.encode(value)),
      const DBusString('text/plain'),
    ]);
    final response = await DBusRemoteObject(
      _client,
      name: _serviceName,
      path: collection,
    )
        .callMethod(_collectionInterface, 'CreateItem', [
          DBusDict.stringVariant({
            'org.freedesktop.Secret.Item.Label': DBusString('NNTDrive $key'),
            'org.freedesktop.Secret.Item.Attributes': _attributes(key),
          }),
          secret,
          const DBusBoolean(true),
        ])
        .timeout(timeout);
    final prompt = response.returnValues[1].asObjectPath();
    if (prompt != _rootPath) {
      // A locked collection needs an interactive prompt; do not block startup.
      throw CredentialStoreUnavailable('keyring requires an unlock prompt');
    }
  }

  @override
  Future<void> delete(String key) async {
    final response = await _service
        .callMethod(_serviceInterface, 'SearchItems', [_attributes(key)])
        .timeout(timeout);
    final paths = [
      ...response.returnValues[0].asArray(),
      ...response.returnValues[1].asArray(),
    ];
    for (final path in paths) {
      final item = DBusRemoteObject(
        _client,
        name: _serviceName,
        path: path.asObjectPath(),
      );
      final deleted =
          await item.callMethod(_itemInterface, 'Delete', []).timeout(timeout);
      if (deleted.returnValues[0].asObjectPath() != _rootPath) {
        throw CredentialStoreUnavailable('keyring requires an unlock prompt');
      }
    }
  }

  @override
  Future<void> close() async {
    _session = null;
    await _client.close();
  }
}

// --- Windows credential manager -------------------------------------------

final class _CredentialW extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int type;
  external Pointer<Utf16> targetName;
  external Pointer<Utf16> comment;
  @Uint64()
  external int lastWritten;
  @Uint32()
  external int credentialBlobSize;
  external Pointer<Uint8> credentialBlob;
  @Uint32()
  external int persist;
  @Uint32()
  external int attributeCount;
  external Pointer<Void> attributes;
  external Pointer<Utf16> targetAlias;
  external Pointer<Utf16> userName;
}

typedef _CredWriteNative = Int32 Function(Pointer<_CredentialW>, Uint32);
typedef _CredWriteDart = int Function(Pointer<_CredentialW>, int);
typedef _CredReadNative = Int32 Function(
    Pointer<Utf16>, Uint32, Uint32, Pointer<Pointer<_CredentialW>>);
typedef _CredReadDart = int Function(
    Pointer<Utf16>, int, int, Pointer<Pointer<_CredentialW>>);
typedef _CredDeleteNative = Int32 Function(Pointer<Utf16>, Uint32, Uint32);
typedef _CredDeleteDart = int Function(Pointer<Utf16>, int, int);
typedef _CredFreeNative = Void Function(Pointer<Void>);
typedef _CredFreeDart = void Function(Pointer<Void>);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

class _WindowsApi {
  _WindowsApi()
      : _advapi32 = DynamicLibrary.open('advapi32.dll'),
        _kernel32 = DynamicLibrary.open('kernel32.dll') {
    credWrite = _advapi32.lookupFunction<_CredWriteNative, _CredWriteDart>(
        'CredWriteW');
    credRead =
        _advapi32.lookupFunction<_CredReadNative, _CredReadDart>('CredReadW');
    credDelete = _advapi32.lookupFunction<_CredDeleteNative, _CredDeleteDart>(
        'CredDeleteW');
    credFree =
        _advapi32.lookupFunction<_CredFreeNative, _CredFreeDart>('CredFree');
    getLastError = _kernel32
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  }

  final DynamicLibrary _advapi32;
  final DynamicLibrary _kernel32;
  late final _CredWriteDart credWrite;
  late final _CredReadDart credRead;
  late final _CredDeleteDart credDelete;
  late final _CredFreeDart credFree;
  late final _GetLastErrorDart getLastError;
}

/// Windows Credential Manager, generic credentials under the current user.
class WindowsCredentialStore implements CredentialStore {
  WindowsCredentialStore() : _api = _WindowsApi();

  static const _typeGeneric = 1;
  static const _persistLocalMachine = 2;
  static const _errorNotFound = 1168;

  final _WindowsApi _api;

  @override
  String get label => 'Windows Credential Manager';

  /// Credential target name for [key]; exposed for tests.
  static String targetName(String key) => 'NNTDrive:$key';

  @override
  Future<String?> read(String key) async {
    final target = targetName(key).toNativeUtf16();
    final out = calloc<Pointer<_CredentialW>>();
    try {
      final ok = _api.credRead(target, _typeGeneric, 0, out);
      if (ok == 0) {
        final code = _api.getLastError();
        if (code == _errorNotFound) return null;
        throw CredentialStoreUnavailable('CredReadW failed ($code)');
      }
      final credential = out.value;
      if (credential == nullptr) return null;
      try {
        final size = credential.ref.credentialBlobSize;
        final blob = credential.ref.credentialBlob;
        if (size == 0 || blob == nullptr) return null;
        return utf8.decode(blob.asTypedList(size), allowMalformed: true);
      } finally {
        _api.credFree(credential.cast<Void>());
      }
    } finally {
      calloc.free(target);
      calloc.free(out);
    }
  }

  @override
  Future<void> write(String key, String value) async {
    final bytes = utf8.encode(value);
    final target = targetName(key).toNativeUtf16();
    final user = 'nntdrive'.toNativeUtf16();
    final blob = calloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    final credential = calloc<_CredentialW>();
    try {
      blob.asTypedList(bytes.length).setAll(0, bytes);
      credential.ref
        ..flags = 0
        ..type = _typeGeneric
        ..targetName = target
        ..comment = nullptr
        ..lastWritten = 0
        ..credentialBlobSize = bytes.length
        ..credentialBlob = blob
        ..persist = _persistLocalMachine
        ..attributeCount = 0
        ..attributes = nullptr
        ..targetAlias = nullptr
        ..userName = user;
      final ok = _api.credWrite(credential, 0);
      if (ok == 0) {
        throw CredentialStoreUnavailable(
            'CredWriteW failed (${_api.getLastError()})');
      }
    } finally {
      calloc.free(credential);
      calloc.free(blob);
      calloc.free(target);
      calloc.free(user);
    }
  }

  @override
  Future<void> delete(String key) async {
    final target = targetName(key).toNativeUtf16();
    try {
      final ok = _api.credDelete(target, _typeGeneric, 0);
      if (ok == 0) {
        final code = _api.getLastError();
        if (code == _errorNotFound) return;
        throw CredentialStoreUnavailable('CredDeleteW failed ($code)');
      }
    } finally {
      calloc.free(target);
    }
  }

  @override
  Future<void> close() async {}
}
