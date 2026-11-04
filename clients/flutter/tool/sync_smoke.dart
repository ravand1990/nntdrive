// Headless end-to-end test of the Dart FFI sync path against a live backend.
//
//   NNTDRIVE_FFI_PATH=... dart run tool/sync_smoke.dart <server> [workdir]

// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

Future<void> main(List<String> args) async {
  final server = args.isNotEmpty ? args[0] : 'http://127.0.0.1:8080';
  final base = Directory(args.length > 1
      ? args[1]
      : Directory.systemTemp.createTempSync('nntdrive-sync-smoke-').path);
  const uuid = Uuid();
  final bridge = NativeBridge.instance;

  final account = await bridge.generateAccountAsync('sync smoke password');
  final accountId = account['account_id'] as String;
  final api = ApiClient(baseUrl: server);
  final registration = await api.register(
    accountId: accountId,
    email: 'sync-smoke-${uuid.v4()}@example.com',
    verifier: account['verifier'] as String,
    keyfile: account['keyfile'] as Map<String, dynamic>,
    device: {
      'id': uuid.v4(),
      'name': 'sync-smoke',
      'platform': 'linux',
      'public_key': bridge.deviceIdentity()['public_key'],
    },
  );
  final token = registration['token'] as String;
  api.token = token;

  final unlocked = await bridge.unlockAsync(
    _json(account['keyfile']),
    'sync smoke password',
  );
  final handle = unlocked['handle'] as int;

  final rootId = uuid.v4();
  final sealed = bridge.sealName(handle, rootId, 'SyncRoot');
  await api.createFile(id: rootId, parentId: null, nameEnc: sealed, isDir: true);

  final deviceA = Directory(p.join(base.path, 'device-a'))..createSync(recursive: true);
  final deviceB = Directory(p.join(base.path, 'device-b'))..createSync(recursive: true);
  final journalDir = Directory(p.join(base.path, 'journals'))..createSync(recursive: true);
  File(p.join(deviceA.path, 'hello.txt')).writeAsStringSync('synced through the Dart FFI');

  Future<Map<String, dynamic>> sync(Directory local, String name, String journal) =>
      bridge.syncRunAsync(
        handle: handle,
        baseUrl: server,
        token: token,
        remoteRootId: rootId,
        localPath: local.path,
        journalPath: p.join(journalDir.path, journal),
        deviceName: name,
      );

  final up = await sync(deviceA, 'device-a', 'a.sqlite');
  print('A sync: $up');
  if (up['uploaded'] != 1) {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: expected one upload');
    exit(2);
  }
  final down = await sync(deviceB, 'device-b', 'b.sqlite');
  print('B sync: $down');
  if (down['downloaded'] != 1) {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: expected one download');
    exit(2);
  }
  final bFile = File(p.join(deviceB.path, 'hello.txt'));
  if (bFile.readAsStringSync() != 'synced through the Dart FFI') {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: downloaded content differs');
    exit(2);
  }

  bFile.writeAsStringSync('edited on device B');
  final bEdit = await sync(deviceB, 'device-b', 'b.sqlite');
  print('B edit sync: $bEdit');
  final aPull = await sync(deviceA, 'device-a', 'a.sqlite');
  print('A pull: $aPull');
  if (File(p.join(deviceA.path, 'hello.txt')).readAsStringSync() != 'edited on device B') {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: edit did not propagate');
    exit(2);
  }

  bridge.lock(handle);
  print('SYNC_FFI_SMOKE_OK: two-folder sync, upload, download and edit propagation');
}

String _json(Object? value) => const JsonEncoder().convert(value);
