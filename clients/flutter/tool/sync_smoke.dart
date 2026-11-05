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
  await api.createFile(
      id: rootId, parentId: null, nameEnc: sealed, isDir: true);

  final deviceA = Directory(p.join(base.path, 'device-a'))
    ..createSync(recursive: true);
  final deviceB = Directory(p.join(base.path, 'device-b'))
    ..createSync(recursive: true);
  final journalDir = Directory(p.join(base.path, 'journals'))
    ..createSync(recursive: true);
  File(p.join(deviceA.path, 'hello.txt'))
      .writeAsStringSync('synced through the Dart FFI');
  final large = List<int>.filled(8 * 1024 * 1024 + 123, 42);
  File(p.join(deviceA.path, 'large.bin')).writeAsBytesSync(large);
  final events = <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> sync(
          Directory local, String name, String journal) =>
      bridge.syncRequestAsync(
          handle,
          {
            'baseUrl': server,
            'token': token,
            'remoteRootId': rootId,
            'localPath': local.path,
            'journalPath': p.join(journalDir.path, journal),
            'deviceName': name,
          },
          onProgress: events.add);

  final up = await sync(deviceA, 'device-a', 'a.sqlite');
  print('A sync: $up');
  if (up['uploaded'] != 2) {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: expected one upload');
    exit(2);
  }
  final down = await sync(deviceB, 'device-b', 'b.sqlite');
  print('B sync: $down');
  if (down['downloaded'] != 2) {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: expected one download');
    exit(2);
  }
  final bFile = File(p.join(deviceB.path, 'hello.txt'));
  for (final direction in ['upload', 'download']) {
    final transfer = events
        .where((e) => e['path'] == 'large.bin' && e['direction'] == direction)
        .toList();
    if (transfer.first['bytes'] != 0 ||
        transfer.last['bytes'] != large.length ||
        transfer.last['complete'] != true ||
        !transfer.any((e) =>
            (e['bytes'] as int) > 0 && (e['bytes'] as int) < large.length)) {
      throw StateError(
          'Missing real incremental $direction progress across FFI');
    }
  }
  if (File(p.join(deviceB.path, 'large.bin')).readAsBytesSync().length !=
      large.length) {
    throw StateError('Large download truncated');
  }
  if (bFile.readAsStringSync() != 'synced through the Dart FFI') {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: downloaded content differs');
    exit(2);
  }

  bFile.writeAsStringSync('edited on device B');
  final bEdit = await sync(deviceB, 'device-b', 'b.sqlite');
  print('B edit sync: $bEdit');
  final aPull = await sync(deviceA, 'device-a', 'a.sqlite');
  print('A pull: $aPull');
  if (File(p.join(deviceA.path, 'hello.txt')).readAsStringSync() !=
      'edited on device B') {
    stderr.writeln('SYNC_FFI_SMOKE_FAILED: edit did not propagate');
    exit(2);
  }

  for (final choice in ['mine', 'theirs', 'both']) {
    final aFile = File(p.join(deviceA.path, 'hello.txt'));
    aFile.writeAsStringSync('theirs-$choice');
    await sync(deviceA, 'device-a', 'a.sqlite');
    bFile.writeAsStringSync('mine-$choice');
    final conflict = await sync(deviceB, 'device-b', 'b.sqlite');
    if (conflict['conflicts'] != 1 || (conflict['errors'] as List).isNotEmpty) {
      throw StateError('Conflict not preserved');
    }
    final copy = deviceB
        .listSync()
        .whereType<File>()
        .singleWhere((f) => p.basename(f.path).contains(' (conflict '));
    await bridge.syncRequestAsync(
        handle,
        {
          'baseUrl': server,
          'token': token,
          'remoteRootId': rootId,
          'localPath': deviceB.path,
          'journalPath': p.join(journalDir.path, 'b.sqlite'),
          'deviceName': 'device-b',
          'original': 'hello.txt',
          'copy': p.basename(copy.path),
          'choice': choice,
        },
        onProgress: events.add);
    await sync(deviceA, 'device-a', 'a.sqlite');
    await sync(deviceB, 'device-b', 'b.sqlite');
    final expected = choice == 'mine' ? 'mine-$choice' : 'theirs-$choice';
    for (final dir in [deviceA, deviceB]) {
      if (File(p.join(dir.path, 'hello.txt')).readAsStringSync() != expected) {
        throw StateError('$choice did not converge');
      }
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => !f.path.endsWith('large.bin'))
          .toList();
      if (files.any((f) => f.path.contains(' (conflict '))) {
        throw StateError('Unresolved conflict remains');
      }
      for (final version in ['mine-$choice', 'theirs-$choice']) {
        if (!files.any((f) => f.readAsStringSync() == version)) {
          throw StateError('Lost $version');
        }
      }
    }
    print(
        'FFI_CONFLICT_OK: keep-$choice converged on both devices; both versions recoverable');
  }
  bridge.lock(handle);
  print(
      'SYNC_FFI_SMOKE_OK: real incremental byte progress and all three conflict choices');
}

String _json(Object? value) => const JsonEncoder().convert(value);
