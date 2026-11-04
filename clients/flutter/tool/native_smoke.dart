// Headless smoke test for the exact Dart FFI layer used by the UI.
//
//   NNTDRIVE_FFI_PATH=... flutter pub run tool/native_smoke.dart <server> <file>
//
// Registers an account, creates a file, uploads/encrypts it with the Rust core,
// downloads and verifies it. Requires a running backend (the dev Compose stack
// includes a mock NNTP provider).

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  final server = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8080';
  final path = args.length > 1 ? args[1] : '/tmp/native-smoke-input.bin';
  const uuid = Uuid();
  final bridge = NativeBridge.instance;

  final email = 'dart-smoke-${uuid.v4()}@example.com';
  final account = await bridge.generateAccountAsync('dart smoke password');
  final accountId = account['account_id'] as String;
  final device = bridge.deviceIdentity();
  final api = ApiClient(baseUrl: server);
  final registration = await api.register(
    accountId: accountId,
    email: email,
    verifier: account['verifier'] as String,
    keyfile: account['keyfile'] as Map<String, dynamic>,
    device: {
      'id': uuid.v4(),
      'name': 'dart-smoke',
      'platform': 'linux',
      'public_key': device['public_key'],
    },
  );
  final token = registration['token'] as String;
  api.token = token;

  // Exercise the same lookup + verifier login path the login screen uses.
  final lookedUp = await api.lookupAccountId(email);
  if (lookedUp != accountId) {
    stderr.writeln('SMOKE FAILED: account lookup returned $lookedUp');
    exit(2);
  }
  final loginVerifier = await bridge.deriveVerifierAsync(
    'dart smoke password',
    accountId,
  );
  final login = await api.loginWithVerifier(email, loginVerifier);
  if ((login['token'] as String?)?.isNotEmpty != true) {
    stderr.writeln('SMOKE FAILED: login did not return a token');
    exit(2);
  }

  final unlocked = await bridge.unlockAsync(
    jsonEncode(account['keyfile']),
    'dart smoke password',
  );
  final handle = unlocked['handle'] as int;

  final fileId = uuid.v4();
  final revisionId = uuid.v4();
  final sealedName = bridge.sealName(handle, fileId, 'dart-smoke.bin');
  await api.createFile(id: fileId, parentId: null, nameEnc: sealedName, isDir: false);

  print('uploading ${File(path).lengthSync()} bytes via Dart FFI ...');
  final up = await bridge.uploadAsync(
    handle: handle,
    baseUrl: server,
    token: token,
    fileId: fileId,
    revisionId: revisionId,
    parentRevision: '',
    path: path,
  );
  print('upload result: $up');

  final dest = '${Directory.systemTemp.path}/dart-smoke-${uuid.v4()}.bin';
  final down = await bridge.downloadAsync(
    handle: handle,
    baseUrl: server,
    token: token,
    fileId: fileId,
    revisionId: revisionId,
    destination: dest,
  );
  print('download result: $down');

  final source = File(path).readAsBytesSync();
  final result = File(dest).readAsBytesSync();
  if (source.length != result.length ||
      !const ListEquality().equals(source, result)) {
    stderr.writeln('SMOKE FAILED: downloaded bytes differ');
    exit(2);
  }
  File(dest).deleteSync();
  bridge.lock(handle);
  print('DART_FFI_SMOKE_OK: upload, download, decrypt and verify succeeded');
}

class ListEquality {
  const ListEquality();
  bool equals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
