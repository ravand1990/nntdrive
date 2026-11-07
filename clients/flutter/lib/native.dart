// Dart bindings for the Rust client core (crates/ffi).
//
// All crypto and content handling happens in Rust. Dart only passes UTF-8 JSON
// and never sees plaintext keys. Long upload/download calls run in an isolate.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

class NativeException implements Exception {
  NativeException(this.message);
  final String message;
  @override
  String toString() => message;
}

typedef _Str1Native = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Str1Dart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _Str2Native = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _Str2Dart = Pointer<Utf8> Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _Handle1Native = Pointer<Utf8> Function(Uint64);
typedef _Handle1Dart = Pointer<Utf8> Function(int);
typedef _Handle2Native = Pointer<Utf8> Function(
    Uint64, Pointer<Utf8>, Pointer<Utf8>);
typedef _Handle2Dart = Pointer<Utf8> Function(
    int, Pointer<Utf8>, Pointer<Utf8>);
typedef _UploadNative = Pointer<Utf8> Function(Uint64, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _UploadDart = Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DownloadNative = Pointer<Utf8> Function(Uint64, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _DownloadDart = Pointer<Utf8> Function(int, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _VersionNative = Uint32 Function();
typedef _VersionDart = int Function();
typedef _SyncExNative = Pointer<Utf8> Function(
    Uint64,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>);
typedef _SyncExDart = Pointer<Utf8> Function(int, Pointer<Utf8>, Pointer<Utf8>,
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

typedef _ProgressNative = Void Function(Pointer<Utf8>);
typedef _RequestNative = Pointer<Utf8> Function(
    Uint64, Pointer<Utf8>, Pointer<NativeFunction<_ProgressNative>>);
typedef _RequestDart = Pointer<Utf8> Function(
    int, Pointer<Utf8>, Pointer<NativeFunction<_ProgressNative>>);

// Keep the worker closure outside the receiving callback's lexical context:
// Dart otherwise captures unsendable completers/listeners implicitly.
Future<Map<String, dynamic>> _runSyncRequest(
        int handle, String encoded, int address) =>
    Isolate.run(
        () => NativeBridge.instance._syncRequest(handle, encoded, address));

class NativeBridge {
  NativeBridge._(this._lib) {
    _free = _lib.lookupFunction<_FreeNative, _FreeDart>('nntdrive_string_free');
    final version = _lib
        .lookupFunction<_VersionNative, _VersionDart>('nntdrive_abi_version')();
    if (version != 1) {
      throw NativeException('Unsupported native core ABI version $version');
    }
  }

  static NativeBridge? _instance;
  static NativeBridge get instance => _instance ??= NativeBridge._(_open());

  final DynamicLibrary _lib;
  late final _FreeDart _free;

  static DynamicLibrary _open() {
    try {
      final override = Platform.environment['NNTDRIVE_FFI_PATH'];
      if (override != null && override.isNotEmpty) {
        return DynamicLibrary.open(override);
      }
      if (Platform.isAndroid) {
        return DynamicLibrary.open('libnntdrive_ffi.so');
      }
      if (Platform.isWindows) {
        return DynamicLibrary.open('nntdrive_ffi.dll');
      }
      if (Platform.isLinux) {
        final exeDir = File(Platform.resolvedExecutable).parent;
        final bundled = File('${exeDir.path}/lib/libnntdrive_ffi.so');
        if (bundled.existsSync()) {
          return DynamicLibrary.open(bundled.path);
        }
        return DynamicLibrary.open('libnntdrive_ffi.so');
      }
      if (Platform.isMacOS) {
        return DynamicLibrary.open('libnntdrive_ffi.dylib');
      }
    } catch (e) {
      throw NativeException('Cannot load the NNTDrive native core: $e\n'
          'Build it with scripts/build-clients.sh (Linux/Android) and bundle it with the app.');
    }
    throw NativeException('Unsupported platform for the native core');
  }

  Pointer<Utf8> _cstr(String value) => value.toNativeUtf8();

  Map<String, dynamic> _decode(Pointer<Utf8> ptr) {
    try {
      if (ptr == nullptr) {
        throw NativeException('native core returned null');
      }
      final text = ptr.toDartString();
      final value = jsonDecode(text);
      if (value is! Map<String, dynamic>) {
        throw NativeException('native core returned malformed JSON');
      }
      if (value['ok'] != true) {
        throw NativeException(
            value['error']?.toString() ?? 'native operation failed');
      }
      return value;
    } finally {
      _free(ptr);
    }
  }

  /// Local-only canonical/case comparison; never send this value to the API.
  String nameCollisionKey(String name) {
    final f = _lib.lookupFunction<_Str1Native, _Str1Dart>(
        'nntdrive_name_collision_key');
    final p = _cstr(name);
    try {
      return _decode(f(p))['comparison'] as String;
    } finally {
      malloc.free(p);
    }
  }

  Map<String, dynamic> generateAccount(String password) {
    final f = _lib
        .lookupFunction<_Str1Native, _Str1Dart>('nntdrive_generate_account');
    final p = _cstr(password);
    try {
      return _decode(f(p));
    } finally {
      malloc.free(p);
    }
  }

  Future<Map<String, dynamic>> generateAccountAsync(String password) =>
      Isolate.run(() => NativeBridge.instance.generateAccount(password));

  Future<String> deriveVerifierAsync(String password, String accountId) =>
      Isolate.run(
          () => NativeBridge.instance.deriveVerifier(password, accountId));

  Future<Map<String, dynamic>> unlockAsync(
          String keyfileJson, String password) =>
      Isolate.run(() => NativeBridge.instance.unlock(keyfileJson, password));

  String deriveVerifier(String password, String accountId) {
    final f =
        _lib.lookupFunction<_Str2Native, _Str2Dart>('nntdrive_derive_verifier');
    final a = _cstr(password);
    final b = _cstr(accountId);
    try {
      return _decode(f(a, b))['verifier'] as String;
    } finally {
      malloc.free(a);
      malloc.free(b);
    }
  }

  Map<String, dynamic> unlock(String keyfileJson, String password) {
    final f = _lib.lookupFunction<_Str2Native, _Str2Dart>('nntdrive_unlock');
    final a = _cstr(keyfileJson);
    final b = _cstr(password);
    try {
      return _decode(f(a, b));
    } finally {
      malloc.free(a);
      malloc.free(b);
    }
  }

  void lock(int handle) {
    final f = _lib.lookupFunction<Void Function(Uint64), void Function(int)>(
        'nntdrive_lock');
    f(handle);
  }

  Map<String, dynamic> deviceIdentity() {
    final f = _lib.lookupFunction<_Handle1Native, _Handle1Dart>(
        'nntdrive_device_identity');
    return _decode(f(0));
  }

  Map<String, dynamic> recoveryKit(int handle) {
    final f = _lib
        .lookupFunction<_Handle1Native, _Handle1Dart>('nntdrive_recovery_kit');
    return _decode(f(handle));
  }

  String sealName(int handle, String nodeId, String name) {
    final f =
        _lib.lookupFunction<_Handle2Native, _Handle2Dart>('nntdrive_seal_name');
    final a = _cstr(nodeId);
    final b = _cstr(name);
    try {
      return _decode(f(handle, a, b))['name_enc'] as String;
    } finally {
      malloc.free(a);
      malloc.free(b);
    }
  }

  String openName(int handle, String nodeId, String nameEncB64) {
    final f =
        _lib.lookupFunction<_Handle2Native, _Handle2Dart>('nntdrive_open_name');
    final a = _cstr(nodeId);
    final b = _cstr(nameEncB64);
    try {
      return _decode(f(handle, a, b))['name'] as String;
    } finally {
      malloc.free(a);
      malloc.free(b);
    }
  }

  Map<String, dynamic> upload({
    required int handle,
    required String baseUrl,
    required String token,
    required String fileId,
    required String revisionId,
    required String parentRevision,
    required String path,
  }) {
    final f =
        _lib.lookupFunction<_UploadNative, _UploadDart>('nntdrive_upload');
    final args = [baseUrl, token, fileId, revisionId, parentRevision, path]
        .map(_cstr)
        .toList();
    try {
      return _decode(
          f(handle, args[0], args[1], args[2], args[3], args[4], args[5]));
    } finally {
      for (final a in args) {
        malloc.free(a);
      }
    }
  }

  Map<String, dynamic> download({
    required int handle,
    required String baseUrl,
    required String token,
    required String fileId,
    required String revisionId,
    required String destination,
  }) {
    final f = _lib
        .lookupFunction<_DownloadNative, _DownloadDart>('nntdrive_download');
    final args =
        [baseUrl, token, fileId, revisionId, destination].map(_cstr).toList();
    try {
      return _decode(f(handle, args[0], args[1], args[2], args[3], args[4]));
    } finally {
      for (final a in args) {
        malloc.free(a);
      }
    }
  }

  Map<String, dynamic> syncRun({
    required int handle,
    required String baseUrl,
    required String token,
    required String remoteRootId,
    required String localPath,
    required String journalPath,
    required String deviceName,
    String excludedJson = '[]',
  }) {
    final f =
        _lib.lookupFunction<_SyncExNative, _SyncExDart>('nntdrive_sync_run_ex');
    final args = [
      baseUrl,
      token,
      remoteRootId,
      localPath,
      journalPath,
      deviceName,
      excludedJson,
    ].map(_cstr).toList();
    try {
      return _decode(f(handle, args[0], args[1], args[2], args[3], args[4],
          args[5], args[6]));
    } finally {
      for (final a in args) {
        malloc.free(a);
      }
    }
  }

  Future<Map<String, dynamic>> syncRunAsync({
    required int handle,
    required String baseUrl,
    required String token,
    required String remoteRootId,
    required String localPath,
    required String journalPath,
    required String deviceName,
    String excludedJson = '[]',
  }) {
    final args = <String, dynamic>{
      'handle': handle,
      'baseUrl': baseUrl,
      'token': token,
      'remoteRootId': remoteRootId,
      'localPath': localPath,
      'journalPath': journalPath,
      'deviceName': deviceName,
      'excludedJson': excludedJson,
    };
    return Isolate.run(() {
      final a = args;
      return NativeBridge.instance.syncRun(
        handle: a['handle'] as int,
        baseUrl: a['baseUrl'] as String,
        token: a['token'] as String,
        remoteRootId: a['remoteRootId'] as String,
        localPath: a['localPath'] as String,
        journalPath: a['journalPath'] as String,
        deviceName: a['deviceName'] as String,
        excludedJson: a['excludedJson'] as String,
      );
    });
  }

  // Isolate helpers: all parameters are primitives, so nothing unsafe crosses
  /// Runs the core off the UI thread. NativeCallable.listener is deliberately
  /// created on the receiving isolate: Tokio threads may emit events freely.
  Future<Map<String, dynamic>> syncRequestAsync(
      int handle, Map<String, dynamic> request,
      {void Function(Map<String, dynamic>)? onProgress}) async {
    // Fail before creating a callback if an old DLL is accidentally bundled.
    _lib.lookupFunction<_RequestNative, _RequestDart>('nntdrive_sync_request');
    final finished = Completer<void>();
    final listener =
        NativeCallable<_ProgressNative>.listener((Pointer<Utf8> ptr) {
      try {
        final event = jsonDecode(ptr.toDartString()) as Map<String, dynamic>;
        if (event['finished'] == true) {
          if (!finished.isCompleted) finished.complete();
        } else {
          onProgress?.call(event);
        }
      } finally {
        _free(ptr);
      }
    });
    final address = listener.nativeFunction.address;
    final encoded = jsonEncode(request);
    try {
      final result = await _runSyncRequest(handle, encoded, address);
      await finished.future;
      if (result['ok'] != true) {
        throw NativeException(result['error'].toString());
      }
      return result;
    } finally {
      listener.close();
    }
  }

  Map<String, dynamic> _syncRequest(int handle, String request, int callback) {
    final f = _lib
        .lookupFunction<_RequestNative, _RequestDart>('nntdrive_sync_request');
    final input = _cstr(request);
    try {
      final output = f(handle, input,
          Pointer<NativeFunction<_ProgressNative>>.fromAddress(callback));
      try {
        return _decode(output);
      } on NativeException catch (e) {
        return {'ok': false, 'error': e.message};
      }
    } finally {
      malloc.free(input);
    }
  }

  // Isolate helpers: all parameters are primitives, so nothing unsafe crosses
  // an isolate boundary.
  Future<Map<String, dynamic>> uploadAsync({
    required int handle,
    required String baseUrl,
    required String token,
    required String fileId,
    required String revisionId,
    required String parentRevision,
    required String path,
  }) {
    final args = <String, dynamic>{
      'handle': handle,
      'baseUrl': baseUrl,
      'token': token,
      'fileId': fileId,
      'revisionId': revisionId,
      'parentRevision': parentRevision,
      'path': path,
    };
    return Isolate.run(() {
      final a = args;
      return NativeBridge.instance.upload(
        handle: a['handle'] as int,
        baseUrl: a['baseUrl'] as String,
        token: a['token'] as String,
        fileId: a['fileId'] as String,
        revisionId: a['revisionId'] as String,
        parentRevision: a['parentRevision'] as String,
        path: a['path'] as String,
      );
    });
  }

  Future<Map<String, dynamic>> downloadAsync({
    required int handle,
    required String baseUrl,
    required String token,
    required String fileId,
    required String revisionId,
    required String destination,
  }) {
    final args = <String, dynamic>{
      'handle': handle,
      'baseUrl': baseUrl,
      'token': token,
      'fileId': fileId,
      'revisionId': revisionId,
      'destination': destination,
    };
    return Isolate.run(() {
      final a = args;
      return NativeBridge.instance.download(
        handle: a['handle'] as int,
        baseUrl: a['baseUrl'] as String,
        token: a['token'] as String,
        fileId: a['fileId'] as String,
        revisionId: a['revisionId'] as String,
        destination: a['destination'] as String,
      );
    });
  }
}
