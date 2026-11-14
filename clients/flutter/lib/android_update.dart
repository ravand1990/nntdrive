//! Android update check, verified download and installer handoff.
//!
//! The desktop clients replace themselves in place. Android cannot: the release
//! APK must be handed to the system package installer, which always asks the
//! user to confirm, and an in-place upgrade needs a stable signing key (tracked
//! separately). This file keeps the check/verify/deferral logic free of platform
//! calls so it can be unit-tested, and reaches Android only through the
//! `dev.nntdrive/update_install` channel.
//!
//! The release feed is the same one the desktop updater uses. Each release must
//! publish `nntdrive-<version>-android.json` with its Android version code and a
//! `SHA256SUMS.txt` entry for the APK; a release missing either is rejected
//! instead of offering an unverifiable upgrade.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'updater.dart';

const androidApkAssetSuffix = '-android.apk';
const androidVersionAssetSuffix = '-android.json';

/// Preference key holding the deferred Android version code. Version codes are
/// monotonic, so a deferral suppresses exactly one release.
const androidSkippedVersionCodeKey = 'androidUpdateSkippedVersionCode';

String androidApkAssetName(String version) =>
    'nntdrive-$version$androidApkAssetSuffix';

String androidVersionAssetName(String version) =>
    'nntdrive-$version$androidVersionAssetSuffix';

/// Android compares version codes, not display versions: a rebuilt or re-tagged
/// release can show a newer name while the installed build stays newer on disk.
bool isNewerVersionCode(int candidate, int installed) => candidate > installed;

/// Reads the release's published version code. Returns null for anything that
/// is not a positive integer so the caller can fail closed.
int? parseAndroidVersionCode(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final raw = decoded['versionCode'];
      if (raw is int) return raw > 0 ? raw : null;
      if (raw is String) {
        final parsed = int.tryParse(raw.trim());
        return parsed != null && parsed > 0 ? parsed : null;
      }
      return null;
    }
    if (decoded is int) return decoded > 0 ? decoded : null;
  } on FormatException {
    return null;
  }
  return null;
}

/// The released APK asset: the versioned name first, then any versioned APK
/// alias so a renamed asset cannot silently disable Android updates.
Map<String, dynamic>? selectAndroidAsset(
    List<Map<String, dynamic>> assets, String version) {
  final expected = androidApkAssetName(version);
  for (final asset in assets) {
    if (asset['name'] == expected) return asset;
  }
  for (final asset in assets) {
    final name = asset['name'];
    if (name is String &&
        name.startsWith('nntdrive-') &&
        name.endsWith(androidApkAssetSuffix)) {
      return asset;
    }
  }
  return null;
}

/// An APK without a published checksum is never installed.
String requireChecksum(String? body, String assetName) {
  final checksum = body == null ? null : parseChecksum(body, assetName);
  if (checksum == null) {
    throw const UpdateException(
        'The release publishes no checksum for its Android package, so the '
        'download cannot be verified. Nothing was installed.');
  }
  return checksum;
}

class InstalledAndroidBuild {
  const InstalledAndroidBuild({required this.version, required this.versionCode});

  final String version;
  final int versionCode;
}

class AndroidUpdateInfo {
  const AndroidUpdateInfo({
    required this.version,
    required this.versionCode,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.size,
    required this.sha256,
  });

  final String version;
  final int versionCode;
  final String notes;
  final String assetName;
  final Uri assetUrl;
  final int size;
  final String sha256;
}

/// What the system installer needs before it can be opened.
class AndroidInstallReadiness {
  const AndroidInstallReadiness({
    required this.supported,
    required this.canRequestPackageInstalls,
  });

  final bool supported;

  /// Android 8+ keeps a per-app switch for "install unknown apps". Below that
  /// the switch is device-wide and cannot be read per app, so this is true.
  final bool canRequestPackageInstalls;
}

class AndroidInstallStart {
  const AndroidInstallStart({required this.started, required this.needsPermission});

  final bool started;
  final bool needsPermission;
}

/// Thin wrapper over the Android channel. Every value is treated as untrusted:
/// an unexpected shape becomes "not available" instead of a crash.
class AndroidInstallChannel {
  const AndroidInstallChannel(
      [this.channel = const MethodChannel('dev.nntdrive/update_install')]);

  final MethodChannel channel;

  Future<AndroidInstallReadiness> readiness() async {
    final raw = await channel.invokeMapMethod<String, Object?>('readiness');
    return AndroidInstallReadiness(
      supported: raw?['supported'] == true,
      canRequestPackageInstalls: raw?['canRequestPackageInstalls'] == true,
    );
  }

  Future<void> openSettings() => channel.invokeMethod<void>('openSettings');

  Future<AndroidInstallStart> start(String stagedPath, String sha256) async {
    final raw = await channel.invokeMapMethod<String, Object?>(
        'install', {'path': stagedPath, 'sha256': sha256});
    return AndroidInstallStart(
      started: raw?['started'] == true,
      needsPermission: raw?['needsPermission'] == true,
    );
  }
}

class AndroidUpdater {
  AndroidUpdater({
    required this.config,
    http.Client? client,
    Future<InstalledAndroidBuild> Function()? installed,
    AndroidInstallChannel? channel,
  })  : _client = client,
        _installed = installed ?? _installedBuild,
        _channel = channel ?? const AndroidInstallChannel();

  final UpdateConfig config;
  final http.Client? _client;
  final Future<InstalledAndroidBuild> Function() _installed;
  final AndroidInstallChannel _channel;

  static const defaultRepo = String.fromEnvironment(
    'NNTDRIVE_UPDATE_REPO',
    defaultValue: 'ravand1990/nntdrive',
  );

  static Future<InstalledAndroidBuild> _installedBuild() async {
    final info = await PackageInfo.fromPlatform();
    final code = int.tryParse(info.buildNumber.trim());
    if (code == null || code <= 0) {
      throw const UpdateException(
          'This build does not report an Android version code, so updates '
          'cannot be compared safely.');
    }
    return InstalledAndroidBuild(version: info.version, versionCode: code);
  }

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'NNTDrive-android-updater',
        if (config.token.isNotEmpty) 'Authorization': 'Bearer ${config.token}',
      };

  Future<http.Response> _get(Uri uri) async {
    final client = _client;
    if (client != null) {
      return client.get(uri, headers: _headers);
    }
    return http.get(uri, headers: _headers);
  }

  /// Returns null when the installed build is current. Throws a readable
  /// [UpdateException] when the feed or its verification data is unusable.
  Future<AndroidUpdateInfo?> check() async {
    final installed = await _installed();
    final res = await _get(
        Uri.parse('https://api.github.com/repos/${config.repo}/releases/latest'));
    if (res.statusCode == 404) {
      throw const UpdateException(
        'Could not read the latest release. Check the repository name, and for '
        'a private repository make sure the access token has Contents: Read '
        'permission for it.',
      );
    }
    if (res.statusCode == 401) {
      throw const UpdateException(
          'The access token was rejected. Check that it is valid and has not expired.');
    }
    if (res.statusCode != 200) {
      throw UpdateException('GitHub release check failed (${res.statusCode}).');
    }
    final release = jsonDecode(res.body) as Map<String, dynamic>;
    final tag =
        (release['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^v'), '');
    if (tag.isEmpty) {
      throw const UpdateException('The latest release has no version tag.');
    }
    final assets = (release['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    final apk = selectAndroidAsset(assets, tag);
    if (apk == null) {
      throw UpdateException('Release $tag has no Android package asset.');
    }
    final apkName = apk['name'] as String;

    final versionAsset = assets
        .where((a) => a['name'] == androidVersionAssetName(tag))
        .toList();
    if (versionAsset.isEmpty) {
      throw UpdateException(
          'Release $tag does not publish its Android version code, so it '
          'cannot be compared with this build. Nothing will be offered.');
    }
    final releaseCode = parseAndroidVersionCode(
        (await _get(_assetUri(versionAsset.first))).body);
    if (releaseCode == null) {
      throw UpdateException(
          'Release $tag published an unreadable Android version code.');
    }
    if (!isNewerVersionCode(releaseCode, installed.versionCode)) return null;

    final sums = assets.where((a) => a['name'] == 'SHA256SUMS.txt').toList();
    if (sums.isEmpty) {
      throw UpdateException(
          'Release $tag publishes no checksum file, so the download cannot be '
          'verified. Nothing will be offered.');
    }
    final sumsRes = await _get(_assetUri(sums.first));
    if (sumsRes.statusCode != 200) {
      throw UpdateException(
          'Could not read the checksum file for release $tag (${sumsRes.statusCode}).');
    }
    final checksum = requireChecksum(sumsRes.body, apkName);

    return AndroidUpdateInfo(
      version: tag,
      versionCode: releaseCode,
      notes: (release['body'] as String? ?? '').trim(),
      assetName: apkName,
      assetUrl: _assetUri(apk),
      size: (apk['size'] as num?)?.toInt() ?? 0,
      sha256: checksum,
    );
  }

  Uri _assetUri(Map<String, dynamic> asset) {
    if (config.token.isNotEmpty && asset['url'] is String) {
      return Uri.parse(asset['url'] as String);
    }
    return Uri.parse(asset['browser_download_url'] as String);
  }

  /// The deferred version code, if the user chose "Later" for this release.
  Future<int?> deferredVersionCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(androidSkippedVersionCodeKey);
  }

  Future<void> defer(AndroidUpdateInfo info) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(androidSkippedVersionCodeKey, info.versionCode);
  }

  /// Downloads the APK and verifies its published SHA-256. A mismatch deletes
  /// the file and throws: an unverified package never reaches the installer.
  Future<File> download(AndroidUpdateInfo info) async {
    final tmp = await getTemporaryDirectory();
    final file = File(p.join(tmp.path, info.assetName));
    try {
      if (file.existsSync()) file.deleteSync();
      final client = _client ?? http.Client();
      try {
        final req = http.Request('GET', info.assetUrl);
        req.headers.addAll(_headers);
        if (config.token.isNotEmpty) {
          req.headers['Accept'] = 'application/octet-stream';
        }
        final res = await client.send(req);
        if (res.statusCode != 200) {
          throw UpdateException(
              'Update download failed (${res.statusCode}). Nothing was installed.');
        }
        final sink = file.openWrite();
        try {
          await res.stream.pipe(sink);
        } finally {
          await sink.close();
        }
      } finally {
        if (_client == null) client.close();
      }
      final actual = await sha256.bind(file.openRead()).first;
      if (actual.toString().toLowerCase() != info.sha256.toLowerCase()) {
        throw const UpdateException(
            'The downloaded update did not match its published checksum. '
            'Nothing was installed.');
      }
      return file;
    } catch (_) {
      if (file.existsSync()) file.deleteSync();
      rethrow;
    }
  }

  /// Downloads, verifies and hands the package to the system installer. The
  /// caller shows the confirmation; Android always asks the user to finish.
  Future<AndroidInstallStart> install(AndroidUpdateInfo info) async {
    final readiness = await _channel.readiness();
    if (!readiness.supported) {
      throw const UpdateException(
          'This Android version cannot install app updates from inside the app.');
    }
    if (!readiness.canRequestPackageInstalls) {
      return const AndroidInstallStart(started: false, needsPermission: true);
    }
    final file = await download(info);
    return _channel.start(file.path, info.sha256);
  }

  Future<void> openInstallSettings() => _channel.openSettings();
}
