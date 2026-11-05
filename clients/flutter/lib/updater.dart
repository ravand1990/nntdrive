//! Desktop auto-updater backed by GitHub Releases.
//!
//! The release workflow attaches `nntdrive-windows-x64.zip`,
//! `nntdrive-linux-x64.tar.gz` and `SHA256SUMS.txt`. This service checks the
//! latest release, verifies the download, stages it, then hands off to a small
//! helper that replaces the running app after it exits and restarts it.
//!
//! The release repository is private today. Users can enter a read-only token
//! in the client's update settings; it is stored with the app's local settings.
//! Builds can also provide a fallback with `--dart-define=NNTDRIVE_UPDATE_TOKEN`.
//! Once releases are public neither is needed.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpdateConfig {
  const UpdateConfig({required this.repo, required this.token});

  final String repo;
  final String token;
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.notes,
    required this.assetName,
    required this.assetUrl,
    required this.size,
    this.sha256,
  });

  final String version;
  final String notes;
  final String assetName;
  final Uri assetUrl;
  final int size;
  final String? sha256;
}

class Updater {
  Updater(this.config);

  final UpdateConfig config;

  static const defaultRepo = String.fromEnvironment(
    'NNTDRIVE_UPDATE_REPO',
    defaultValue: 'ravand1990/nntdrive',
  );
  static const _compileToken = String.fromEnvironment('NNTDRIVE_UPDATE_TOKEN');
  static const _repoKey = 'updateRepo';
  static const _tokenKey = 'updateToken';

  static bool get supported => Platform.isWindows || Platform.isLinux;

  /// Settings are stored per install. The token is optional and only needed
  /// while the release repository is private; use a read-only token.
  static Future<UpdateConfig> loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final repo = (prefs.getString(_repoKey) ?? '').trim();
    var token = (prefs.getString(_tokenKey) ?? '').trim();
    if (token.isEmpty) {
      token = _compileToken.isNotEmpty
          ? _compileToken
          : (Platform.environment['NNTDRIVE_UPDATE_TOKEN'] ?? '');
    }
    return UpdateConfig(
      repo: repo.isEmpty ? defaultRepo : repo,
      token: token,
    );
  }

  static Future<void> saveConfig({
    required String repo,
    required String token,
    required bool autoCheck,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_repoKey, repo.trim());
    await prefs.setBool('updateAutoCheck', autoCheck);
    final trimmed = token.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(_tokenKey);
    } else {
      await prefs.setString(_tokenKey, trimmed);
    }
  }

  Map<String, String> get _headers => {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'NNTDrive-updater',
        if (config.token.isNotEmpty) 'Authorization': 'Bearer ${config.token}',
      };

  Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// Returns null when the installed version is current. Throws with a
  /// user-readable message when the release feed cannot be read.
  Future<UpdateInfo?> check() async {
    if (!supported) {
      throw const UpdateException('Automatic updates are only supported on Windows and Linux.');
    }
    final current = await currentVersion();
    final res = await http.get(
      Uri.parse('https://api.github.com/repos/${config.repo}/releases/latest'),
      headers: _headers,
    );
    if (res.statusCode == 404) {
      throw const UpdateException(
        'Could not read the latest release. Check the repository name, and for '
        'a private repository make sure the access token has Contents: Read '
        'permission for it.',
      );
    }
    if (res.statusCode == 401) {
      throw const UpdateException('The access token was rejected. Check that it is valid and has not expired.');
    }
    if (res.statusCode != 200) {
      throw UpdateException('GitHub release check failed (${res.statusCode}).');
    }
    final release = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (release['tag_name'] as String? ?? '').replaceFirst(RegExp(r'^v'), '');
    if (tag.isEmpty) throw const UpdateException('The latest release has no version tag.');
    if (!isNewerVersion(tag, current)) return null;

    final assets = (release['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final assetName = platformAssetName();
    final asset = assets.where((a) => a['name'] == assetName).firstOrNull;
    if (asset == null) {
      throw UpdateException('Release $tag has no $assetName asset.');
    }
    final sums = assets
        .where((a) => a['name'] == 'SHA256SUMS.txt')
        .firstOrNull;
    final checksum =
        sums == null ? null : await _fetchChecksum(sums, assetName);
    return UpdateInfo(
      version: tag,
      notes: (release['body'] as String? ?? '').trim(),
      assetName: assetName,
      assetUrl: _assetUri(asset),
      size: (asset['size'] as num?)?.toInt() ?? 0,
      sha256: checksum,
    );
  }

  /// Downloads and verifies the release, stages it, then starts a detached
  /// helper that replaces the install after this process exits. The caller must
  /// terminate the app afterwards.
  Future<void> install(UpdateInfo info) async {
    final tmp = await getTemporaryDirectory();
    final archive = File(p.join(tmp.path, info.assetName));
    final stage = Directory(p.join(tmp.path, 'nntdrive-update-${info.version}'));
    try {
      await _download(info.assetUrl, archive,
          accept: config.token.isEmpty ? null : 'application/octet-stream');
      if (info.sha256 != null) {
        final actual = await sha256.bind(archive.openRead()).first;
        if (actual.toString().toLowerCase() != info.sha256!.toLowerCase()) {
          throw const UpdateException('Downloaded update failed its checksum; nothing was replaced.');
        }
      }
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      stage.createSync(recursive: true);
      if (Platform.isWindows) {
        await _extractZip(archive, stage);
        _launchWindowsHelper(stage);
      } else {
        await _extractTar(archive, stage);
        _launchLinuxHelper(stage);
      }
    } catch (e) {
      if (archive.existsSync()) archive.deleteSync();
      rethrow;
    } finally {
      if (archive.existsSync()) archive.deleteSync();
    }
  }

  Uri _assetUri(Map<String, dynamic> asset) {
    if (config.token.isNotEmpty && asset['url'] is String) {
      return Uri.parse(asset['url'] as String);
    }
    return Uri.parse(asset['browser_download_url'] as String);
  }

  Future<String?> _fetchChecksum(
    Map<String, dynamic> sumsAsset,
    String assetName,
  ) async {
    try {
      final res = await http.get(
        _assetUri(sumsAsset),
        headers: {
          ..._headers,
          if (config.token.isNotEmpty) 'Accept': 'application/octet-stream',
        },
      );
      if (res.statusCode != 200) return null;
      return parseChecksum(res.body, assetName);
    } catch (_) {
      return null;
    }
  }

  Future<void> _download(Uri uri, File destination, {String? accept}) async {
    final client = http.Client();
    try {
      final req = http.Request('GET', uri);
      req.headers.addAll(_headers);
      if (accept != null) req.headers['Accept'] = accept;
      final res = await client.send(req);
      if (res.statusCode != 200) {
        throw UpdateException('Update download failed (${res.statusCode}).');
      }
      final sink = destination.openWrite();
      try {
        await res.stream.pipe(sink);
      } finally {
        await sink.close();
      }
    } finally {
      client.close();
    }
  }

  Future<void> _extractZip(File archive, Directory stage) async {
    final res = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      'Expand-Archive -LiteralPath "${archive.path}" -DestinationPath "${stage.path}" -Force',
    ]);
    if (res.exitCode != 0) {
      throw UpdateException('Could not unpack the update: ${res.stderr}');
    }
  }

  Future<void> _extractTar(File archive, Directory stage) async {
    final res = await Process.run('tar', ['-xzf', archive.path, '-C', stage.path]);
    if (res.exitCode != 0) {
      throw UpdateException('Could not unpack the update: ${res.stderr}');
    }
  }

  void _launchWindowsHelper(Directory stage) {
    final install = p.dirname(Platform.resolvedExecutable);
    final script = File(p.join(stage.parent.path, 'nntdrive-update.cmd'));
    script.writeAsStringSync('''
@echo off
setlocal
:wait
tasklist /FI "PID eq $pid" 2>nul | find "$pid" >nul
if not errorlevel 1 (
  timeout /t 1 /nobreak >nul
  goto wait
)
robocopy "${stage.path}" "$install" /E /NFL /NDL /NJH /NJS /NP >nul
start "" "$install\\nntdrive.exe"
rmdir /s /q "${stage.path}"
del "%~f0"
''');
    Process.start('cmd', ['/c', script.path], mode: ProcessStartMode.detached);
  }

  void _launchLinuxHelper(Directory stage) {
    final install = p.dirname(Platform.resolvedExecutable);
    final script = File(p.join(stage.parent.path, 'nntdrive-update.sh'));
    script.writeAsStringSync('''
#!/bin/sh
while kill -0 $pid 2>/dev/null; do sleep 1; done
cp -a "${stage.path}/." "$install/"
cd "$install" && ./nntdrive >/dev/null 2>&1 &
rm -rf "${stage.path}"
rm -f "\$0"
''');
    Process.runSync('chmod', ['+x', script.path]);
    Process.start('/bin/sh', [script.path], mode: ProcessStartMode.detached);
  }
}

class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

String platformAssetName() {
  if (Platform.isWindows) return 'nntdrive-windows-x64.zip';
  if (Platform.isLinux) return 'nntdrive-linux-x64.tar.gz';
  throw const UpdateException('No updater package exists for this platform.');
}

/// Compares dotted numeric versions, ignoring any `-prerelease` suffix.
bool isNewerVersion(String candidate, String current) {
  List<int> parse(String value) {
    final core = value.toLowerCase().replaceFirst(RegExp(r'^v'), '').split('-').first;
    final parts = core.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return parts.take(3).toList();
  }

  final a = parse(candidate);
  final b = parse(current);
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}

/// Reads `SHA256SUMS.txt` lines (`<hash>  <name>` or `<hash> *<name>`).
String? parseChecksum(String body, String assetName) {
  for (final line in body.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final name = parts.last.replaceFirst(RegExp(r'^\*'), '');
    if (name == assetName && RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(parts.first)) {
      return parts.first.toLowerCase();
    }
  }
  return null;
}
