import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:nntdrive/android_update.dart';
import 'package:nntdrive/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const installChannel = MethodChannel('dev.nntdrive/update_install');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('android-update-');
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => root.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installChannel, null);
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  const apkBytes = 'not-a-real-apk-but-stable-bytes';
  final apkDigest = sha256.convert(utf8.encode(apkBytes)).toString();

  Map<String, dynamic> release({
    String tag = 'v9.0.0',
    int? versionCode = 90,
    bool withSums = true,
    bool withApk = true,
    bool checksumForApk = true,
  }) =>
      {
        'tag_name': tag,
        'body': 'Release notes',
        'assets': [
          if (withApk)
            {
              'name': 'nntdrive-9.0.0-android.apk',
              'browser_download_url':
                  'https://example.invalid/nntdrive-9.0.0-android.apk',
              'size': apkBytes.length,
            },
          if (versionCode != null)
            {
              'name': 'nntdrive-9.0.0-android.json',
              'browser_download_url':
                  'https://example.invalid/nntdrive-9.0.0-android.json',
              'size': 40,
            },
          if (withSums)
            {
              'name': 'SHA256SUMS.txt',
              'browser_download_url': 'https://example.invalid/SHA256SUMS.txt',
              'size': 200,
            },
        ],
        '_versionCode': versionCode,
        '_apkDigest': checksumForApk ? apkDigest : null,
      };

  MockClient feed(Map<String, dynamic> payload, {void Function()? onDownload}) =>
      MockClient((request) async {
        final path = request.url.path;
        if (path.endsWith('/releases/latest')) {
          return http.Response(jsonEncode(payload), 200);
        }
        if (path.endsWith('-android.json')) {
          final code = payload['_versionCode'];
          if (code == null) return http.Response('not json', 404);
          return http.Response(jsonEncode({'versionCode': code}), 200);
        }
        if (path.endsWith('SHA256SUMS.txt')) {
          final digest = payload['_apkDigest'];
          return http.Response(
              digest == null ? '' : '$digest  nntdrive-9.0.0-android.apk', 200);
        }
        if (path.endsWith('.apk')) {
          onDownload?.call();
          return http.Response.bytes(utf8.encode(apkBytes), 200);
        }
        return http.Response('', 404);
      });

  AndroidUpdater updater(
    http.Client client, {
    int installedCode = 40,
  }) =>
      AndroidUpdater(
        config: const UpdateConfig(repo: 'ravand1990/nntdrive', token: ''),
        client: client,
        installed: () async => InstalledAndroidBuild(
            version: '0.12.0', versionCode: installedCode),
      );

  test('version codes are read strictly from the published metadata', () {
    expect(parseAndroidVersionCode('{"versionCode": 41}'), 41);
    expect(parseAndroidVersionCode('{"versionCode": "42"}'), 42);
    expect(parseAndroidVersionCode('43'), 43);
    expect(parseAndroidVersionCode('{"versionCode": 0}'), isNull);
    expect(parseAndroidVersionCode('{"versionCode": -1}'), isNull);
    expect(parseAndroidVersionCode('{"versionCode": "x"}'), isNull);
    expect(parseAndroidVersionCode('{"version": "1.0.0"}'), isNull);
    expect(parseAndroidVersionCode('not json'), isNull);
    expect(isNewerVersionCode(41, 40), isTrue);
    expect(isNewerVersionCode(40, 40), isFalse);
    expect(isNewerVersionCode(39, 40), isFalse);
  });

  test('only a versioned APK asset is selected', () {
    expect(
        selectAndroidAsset([
          {'name': 'nntdrive-9.0.0-android.apk'},
          {'name': 'nntdrive-9.0.0-linux-x64.tar.gz'},
        ], '9.0.0')?['name'],
        'nntdrive-9.0.0-android.apk');
    // A renamed but still versioned APK keeps updates working.
    expect(
        selectAndroidAsset([
          {'name': 'nntdrive-9.0.0-arm64-android.apk'}
        ], '9.0.0')?['name'],
        'nntdrive-9.0.0-arm64-android.apk');
    expect(selectAndroidAsset([{'name': 'nntdrive-9.0.0-windows-x64.zip'}],
        '9.0.0'), isNull);
  });

  test('a missing checksum entry is refused', () {
    expect(() => requireChecksum(null, 'a.apk'), throwsA(isA<UpdateException>()));
    expect(() => requireChecksum('deadbeef  other.apk', 'a.apk'),
        throwsA(isA<UpdateException>()));
    expect(requireChecksum('${'a' * 64}  a.apk', 'a.apk'), 'a' * 64);
  });

  test('a newer version code offers the update with its checksum', () async {
    final info = await updater(feed(release())).check();
    expect(info, isNotNull);
    expect(info!.version, '9.0.0');
    expect(info.versionCode, 90);
    expect(info.assetName, 'nntdrive-9.0.0-android.apk');
    expect(info.sha256, apkDigest);
    expect(info.notes, 'Release notes');
  });

  test('the same or older version code offers nothing', () async {
    expect(await updater(feed(release()), installedCode: 90).check(), isNull);
    expect(await updater(feed(release()), installedCode: 91).check(), isNull);
  });

  test('a release without its version code is refused', () async {
    await expectLater(
      updater(feed(release(versionCode: null))).check(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('version code'))),
    );
  });

  test('a release without checksums is refused instead of offered', () async {
    await expectLater(
      updater(feed(release(withSums: false))).check(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('checksum'))),
    );
    await expectLater(
      updater(feed(release(checksumForApk: false))).check(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('checksum'))),
    );
  });

  test('a release without an Android package is refused', () async {
    await expectLater(
      updater(feed(release(withApk: false))).check(),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('Android package'))),
    );
  });

  test('download verifies the checksum and deletes a mismatch', () async {
    final info = (await updater(feed(release())).check())!;
    final file = await updater(feed(release())).download(info);
    expect(file.existsSync(), isTrue);
    expect(file.readAsStringSync(), apkBytes);

    final tampered = AndroidUpdateInfo(
      version: info.version,
      versionCode: info.versionCode,
      notes: '',
      assetName: info.assetName,
      assetUrl: info.assetUrl,
      size: info.size,
      sha256: 'b' * 64,
    );
    await expectLater(
      updater(feed(release())).download(tampered),
      throwsA(isA<UpdateException>()
          .having((e) => e.message, 'message', contains('checksum'))),
    );
    expect(File('${root.path}/${tampered.assetName}').existsSync(), isFalse);
  });

  test('deferral remembers one version code and a newer one differs', () async {
    final first = (await updater(feed(release())).check())!;
    final target = updater(feed(release()));
    await target.defer(first);
    expect(await target.deferredVersionCode(), 90);

    final newer = (await updater(feed(release(versionCode: 91))).check())!;
    expect(await target.deferredVersionCode(), isNot(newer.versionCode));
  });

  test('install asks for the Android switch before downloading anything',
      () async {
    var downloads = 0;
    var installCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installChannel, (call) async {
      if (call.method == 'readiness') {
        return {'supported': true, 'canRequestPackageInstalls': false};
      }
      if (call.method == 'install') installCalls++;
      return null;
    });
    final info = (await updater(feed(release())).check())!;
    final start = await updater(feed(release(), onDownload: () => downloads++))
        .install(info);
    expect(start.needsPermission, isTrue);
    expect(start.started, isFalse);
    expect(downloads, 0);
    expect(installCalls, 0);
  });

  test('install hands a verified package to the Android installer', () async {
    Map<Object?, Object?>? payload;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(installChannel, (call) async {
      if (call.method == 'readiness') {
        return {'supported': true, 'canRequestPackageInstalls': true};
      }
      if (call.method == 'install') {
        payload = call.arguments as Map<Object?, Object?>;
        return {'started': true, 'needsPermission': false};
      }
      return null;
    });
    final info = (await updater(feed(release())).check())!;
    final start = await updater(feed(release())).install(info);
    expect(start.started, isTrue);
    expect(payload?['sha256'], apkDigest);
    expect(payload?['path'], endsWith('nntdrive-9.0.0-android.apk'));
    expect(File(payload!['path'] as String).readAsStringSync(), apkBytes);
  });
}
