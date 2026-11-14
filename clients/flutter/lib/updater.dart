//! Desktop auto-updater backed by GitHub Releases.
//!
//! The release workflow attaches `nntdrive-<version>-windows-x64.zip`,
//! `nntdrive-<version>-linux-x64.tar.gz` and `SHA256SUMS.txt`. This service
//! checks the latest release, verifies the download, stages it, then hands off
//! to a small helper that replaces the running app after it exits and restarts
//! it.
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

import 'update_handoff.dart';

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
    this.releaseNotes = const [],
    this.olderNotesOmitted = 0,
  });

  final String version;

  /// Plain-text fallback of [releaseNotes], newest version first.
  final String notes;
  final String assetName;
  final Uri assetUrl;
  final int size;
  final String? sha256;

  /// One entry per stable release between the installed build and [version],
  /// newest first. Empty when a feed published no notes, in which case the
  /// update is still offered.
  final List<ReleaseNote> releaseNotes;

  /// Older releases whose notes were dropped by the text caps.
  final int olderNotesOmitted;
}

/// The notes of a single release, kept separate so the prompt can render one
/// heading per version instead of one undifferentiated block of text.
class ReleaseNote {
  const ReleaseNote({required this.version, required this.body});

  final String version;
  final String body;
}

/// Aggregated upgrade notes: [entries] newest first, [omitted] older releases
/// that no longer fit under the caps.
class UpgradeNotes {
  const UpgradeNotes({required this.entries, this.omitted = 0});

  final List<ReleaseNote> entries;
  final int omitted;

  bool get isEmpty => entries.isEmpty;

  /// Plain text used by callers that show notes without structure.
  String get text {
    final buffer = StringBuffer();
    for (final entry in entries) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write('Version ${entry.version}\n\n${entry.body}');
    }
    if (omitted > 0) {
      if (buffer.isNotEmpty) buffer.write('\n\n');
      buffer.write('$omitted older release${omitted == 1 ? '' : 's'} not shown.');
    }
    return buffer.toString();
  }
}

/// Bounds for aggregated notes: enough for a whole minor series without letting
/// a long history flood the update prompt.
const defaultMaxNoteSections = 20;
const defaultMaxNoteBodyChars = 4000;
const defaultMaxNoteTotalChars = 20000;

/// GitHub's maximum page size for the releases endpoint.
const _releasePageSize = 100;
const _maxReleasePages = 10;

class Updater {
  Updater(this.config, {http.Client? client}) : _client = client;

  final UpdateConfig config;

  /// Optional client for tests; production code creates one per request.
  final http.Client? _client;

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
      throw const UpdateException(
          'Automatic updates are only supported on Windows and Linux.');
    }
    final current = await currentVersion();
    final releases = await fetchReleases();
    final target = selectTargetRelease(releases, current);
    if (target == null) return null;
    final tag = releaseTag(target)!;

    final assets = (target['assets'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final asset = selectPlatformAsset(assets, tag);
    if (asset == null) {
      throw UpdateException(
          'Release $tag has no ${platformAssetName(tag)} asset.');
    }
    final assetName = asset['name'] as String;
    final sums = assets.where((a) => a['name'] == 'SHA256SUMS.txt').firstOrNull;
    final checksum =
        sums == null ? null : await _fetchChecksum(sums, assetName);
    final notes = collectUpgradeNotes(releases, installedVersion: current);
    return UpdateInfo(
      version: tag,
      notes: notes.text,
      releaseNotes: notes.entries,
      olderNotesOmitted: notes.omitted,
      assetName: assetName,
      assetUrl: _assetUri(asset),
      size: (asset['size'] as num?)?.toInt() ?? 0,
      sha256: checksum,
    );
  }

  /// Reads the release feed page by page so a full first page never hides older
  /// versions. Drafts and prereleases are returned unfiltered; selection and
  /// notes handle them, because only stable releases are offered.
  Future<List<Map<String, dynamic>>> fetchReleases() async {
    final releases = <Map<String, dynamic>>[];
    for (var page = 1; page <= _maxReleasePages; page++) {
      final res = await _get(
        Uri.parse('https://api.github.com/repos/${config.repo}/releases'
            '?per_page=$_releasePageSize&page=$page'),
        _headers,
      );
      _throwForStatus(res);
      final decoded = jsonDecode(res.body);
      if (decoded is! List) {
        throw const UpdateException(
            'GitHub returned an unexpected release feed.');
      }
      final batch = decoded.whereType<Map<String, dynamic>>().toList();
      releases.addAll(batch);
      if (batch.length < _releasePageSize) break;
    }
    return releases;
  }

  Future<http.Response> _get(Uri uri, Map<String, String> headers) async {
    final client = _client;
    if (client != null) return client.get(uri, headers: headers);
    return http.get(uri, headers: headers);
  }

  void _throwForStatus(http.Response res) {
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
  }

  /// Downloads and verifies the release, stages it, then starts a detached
  /// helper that replaces the install after this process exits. The caller must
  /// terminate the app afterwards.
  Future<void> install(UpdateInfo info) async {
    final tmp = await getTemporaryDirectory();
    final archive = File(p.join(tmp.path, info.assetName));
    final stage =
        Directory(p.join(tmp.path, 'nntdrive-update-${info.version}'));
    try {
      await _download(info.assetUrl, archive,
          accept: config.token.isEmpty ? null : 'application/octet-stream');
      if (info.sha256 != null) {
        final actual = await sha256.bind(archive.openRead()).first;
        if (actual.toString().toLowerCase() != info.sha256!.toLowerCase()) {
          throw const UpdateException(
              'Downloaded update failed its checksum; nothing was replaced.');
        }
      }
      if (stage.existsSync()) stage.deleteSync(recursive: true);
      stage.createSync(recursive: true);
      if (Platform.isWindows) {
        await _extractZip(archive, stage);
        await _launchWindowsHelper(stage);
      } else {
        await _extractTar(archive, stage);
        await _launchLinuxHelper(stage);
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
    final res =
        await Process.run('tar', ['-xzf', archive.path, '-C', stage.path]);
    if (res.exitCode != 0) {
      throw UpdateException('Could not unpack the update: ${res.stderr}');
    }
  }

  Future<void> _launchWindowsHelper(Directory stage) async {
    await launchWindowsUpdateHelper(
      stage: stage,
      install: p.dirname(Platform.resolvedExecutable),
      parentPid: pid,
    );
  }

  Future<void> _launchLinuxHelper(Directory stage) async {
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
    await startUpdateHelper(
      () => Process.start('/bin/sh', [script.path],
          mode: ProcessStartMode.detached),
      () async {},
    );
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

String platformAssetSuffix() {
  if (Platform.isWindows) return '-windows-x64.zip';
  if (Platform.isLinux) return '-linux-x64.tar.gz';
  throw const UpdateException('No updater package exists for this platform.');
}

String platformAssetName(String version) =>
    'nntdrive-$version${platformAssetSuffix()}';

/// Returns the release asset for this platform: the versioned name first, then
/// the unversioned alias kept for clients that predate versioned asset names.
Map<String, dynamic>? selectPlatformAsset(
    List<Map<String, dynamic>> assets, String version) {
  final expected = platformAssetName(version);
  for (final asset in assets) {
    if (asset['name'] == expected) return asset;
  }
  final suffix = platformAssetSuffix();
  for (final asset in assets) {
    final name = asset['name'];
    if (name is String &&
        name.startsWith('nntdrive-') &&
        name.endsWith(suffix)) {
      return asset;
    }
  }
  return null;
}

/// Parses a dotted numeric version (`v` prefix, prerelease and build metadata
/// allowed) into three comparable parts. Returns null for tags that are not
/// ordinary versions, such as `nightly`.
List<int>? parseVersionParts(String value) {
  final core = value
      .trim()
      .toLowerCase()
      .replaceFirst(RegExp(r'^v'), '')
      .split('-')
      .first
      .split('+')
      .first;
  if (core.isEmpty) return null;
  final parts = <int>[];
  for (final piece in core.split('.')) {
    final number = int.tryParse(piece);
    if (number == null || number < 0) return null;
    parts.add(number);
  }
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts.take(3).toList();
}

/// Compares dotted numeric versions, ignoring any `-prerelease` suffix.
/// Unparseable values sort below every real version.
int compareVersions(String a, String b) {
  final left = parseVersionParts(a);
  final right = parseVersionParts(b);
  if (left == null && right == null) return 0;
  if (left == null) return -1;
  if (right == null) return 1;
  for (var i = 0; i < 3; i++) {
    if (left[i] != right[i]) return left[i] > right[i] ? 1 : -1;
  }
  return 0;
}

bool isNewerVersion(String candidate, String current) =>
    compareVersions(candidate, current) > 0;

/// The version a release publishes, without the `v` prefix, or null when the
/// tag is not an ordinary version.
String? releaseTag(Map<String, dynamic> release) {
  final raw = release['tag_name'];
  if (raw is! String) return null;
  final tag = raw.trim().replaceFirst(RegExp(r'^[vV]'), '');
  return parseVersionParts(tag) == null ? null : tag;
}

bool _isStableRelease(Map<String, dynamic> release) =>
    release['prerelease'] != true && release['draft'] != true;

/// The newest stable release newer than [installed], or null when nothing is
/// newer. Used for both the offered version and its download assets.
Map<String, dynamic>? selectTargetRelease(
  List<Map<String, dynamic>> releases,
  String installed,
) {
  Map<String, dynamic>? best;
  String? bestTag;
  for (final release in releases) {
    if (!_isStableRelease(release)) continue;
    final tag = releaseTag(release);
    if (tag == null || !isNewerVersion(tag, installed)) continue;
    if (bestTag == null || compareVersions(tag, bestTag) > 0) {
      best = release;
      bestTag = tag;
    }
  }
  return best;
}

/// Collects the notes of every stable release newer than [installedVersion],
/// newest first. Releases without notes and duplicate versions are skipped, and
/// the result is bounded by section count, per-release text and total text.
UpgradeNotes collectUpgradeNotes(
  List<Map<String, dynamic>> releases, {
  required String installedVersion,
  int maxSections = defaultMaxNoteSections,
  int maxBodyChars = defaultMaxNoteBodyChars,
  int maxTotalChars = defaultMaxNoteTotalChars,
}) {
  final candidates = <ReleaseNote>[];
  final seen = <String>{};
  for (final release in releases) {
    if (!_isStableRelease(release)) continue;
    final tag = releaseTag(release);
    if (tag == null || !isNewerVersion(tag, installedVersion)) continue;
    final body = (release['body'] as String? ?? '').trim();
    if (body.isEmpty) continue;
    final key = parseVersionParts(tag)!.join('.');
    if (!seen.add(key)) continue;
    candidates.add(ReleaseNote(version: tag, body: body));
  }
  candidates.sort((a, b) => compareVersions(b.version, a.version));

  final entries = <ReleaseNote>[];
  var used = 0;
  var omitted = 0;
  for (final note in candidates) {
    final room = maxTotalChars - used;
    if (entries.length >= maxSections || room < 40) {
      omitted++;
      continue;
    }
    var body = note.body;
    if (body.length > maxBodyChars) {
      body = '${body.substring(0, maxBodyChars).trimRight()}…';
    }
    if (body.length > room) {
      body = '${body.substring(0, room).trimRight()}…';
    }
    if (body.isEmpty) {
      omitted++;
      continue;
    }
    entries.add(ReleaseNote(version: note.version, body: body));
    used += body.length;
  }
  return UpgradeNotes(entries: entries, omitted: omitted);
}


/// Reads `SHA256SUMS.txt` lines (`<hash>  <name>` or `<hash> *<name>`).
String? parseChecksum(String body, String assetName) {
  for (final line in body.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final name = parts.last.replaceFirst(RegExp(r'^\*'), '');
    if (name == assetName &&
        RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(parts.first)) {
      return parts.first.toLowerCase();
    }
  }
  return null;
}
