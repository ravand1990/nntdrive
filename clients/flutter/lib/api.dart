// Typed client for the NNTDrive backend.
//
// All content sent through this client is ciphertext. Encryption, chunking,
// erasure coding and the sync engine live in the Rust core; until the native
// bridge (see crypto_service.dart) is built, content operations are disabled.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.status, this.code, this.message);
  final int status;
  final String code;
  final String message;
  @override
  String toString() => '$code ($status): $message';
}

class AccountInfo {
  AccountInfo(this.id, this.email, this.displayName, this.isAdmin, this.quota, this.used);
  final String id;
  final String email;
  final String displayName;
  final bool isAdmin;
  final int? quota;
  final int used;
  List<DeviceInfo> devices = [];

  factory AccountInfo.fromJson(Map<String, dynamic> j) => AccountInfo(
        j['account_id'] as String,
        j['email'] as String? ?? '',
        j['display_name'] as String? ?? '',
        j['is_admin'] as bool? ?? false,
        j['quota_bytes'] as int?,
        j['used_bytes'] as int? ?? 0,
      );
}

class RemoteFile {
  RemoteFile(this.id, this.parentId, this.nameEnc, this.isDir, this.size, this.favorite, this.revision, this.currentVersion, {this.updatedAt});
  final String id;
  final String? parentId;
  final String nameEnc; // sealed bytes, base64
  final bool isDir;
  final int size;
  final bool favorite;
  final int revision;
  final String? currentVersion;
  /// Server namespace modification time; not a verified content timestamp.
  final DateTime? updatedAt;

  factory RemoteFile.fromJson(Map<String, dynamic> j) => RemoteFile(
        j['id'] as String,
        j['parent_id'] as String?,
        j['name_enc'] as String? ?? '',
        j['is_dir'] as bool? ?? false,
        j['size'] as int? ?? 0,
        j['favorite'] as bool? ?? false,
        j['revision'] as int? ?? 0,
        j['current_version'] as String?,
        updatedAt: DateTime.tryParse(j['updated_at'] as String? ?? ''),
      );
}

class DeviceInfo {
  DeviceInfo(this.id, this.name, this.platform, this.revoked, this.current);
  final String id;
  final String name;
  final String platform;
  final bool revoked;
  final bool current;

  factory DeviceInfo.fromJson(Map<String, dynamic> j) => DeviceInfo(
        j['id'] as String,
        j['name'] as String? ?? '',
        j['platform'] as String? ?? '',
        j['revoked_at'] != null,
        j['current'] as bool? ?? false,
      );
}

/// A fixed account root: the account-wide Global space or one device space.
///
/// The backend stores only the node ID and the sealed name; this model carries
/// opaque ciphertext plus device presence metadata. `stale` is a coarse marker
/// computed server-side from revocation or a device that has not signed in for
/// a day; it is informative and never hides or deletes the root.
class AccountRoot {
  AccountRoot({
    required this.rootId,
    required this.kind,
    required this.nodeId,
    required this.nameEnc,
    this.createdAt,
    this.deviceId,
    this.deviceName,
    this.devicePlatform,
    this.deviceLastSeenAt,
    this.deviceRevoked = false,
    this.stale = false,
  });

  final String rootId;
  final String kind; // "global" or "device"
  final String nodeId;
  final String nameEnc; // sealed bytes, base64
  final DateTime? createdAt;
  final String? deviceId;
  final String? deviceName;
  final String? devicePlatform;
  final DateTime? deviceLastSeenAt;
  final bool deviceRevoked;
  final bool stale;

  bool get isGlobal => kind == 'global';

  factory AccountRoot.fromJson(Map<String, dynamic> j) => AccountRoot(
        rootId: j['root_id'] as String,
        kind: j['kind'] as String? ?? '',
        nodeId: j['node_id'] as String,
        nameEnc: j['name_enc'] as String? ?? '',
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? ''),
        deviceId: j['device_id'] as String?,
        deviceName: j['device_name'] as String?,
        devicePlatform: j['device_platform'] as String?,
        deviceLastSeenAt:
            DateTime.tryParse(j['device_last_seen_at'] as String? ?? ''),
        deviceRevoked: j['device_revoked'] as bool? ?? false,
        stale: j['stale'] as bool? ?? false,
      );
}

class VersionInfo {
  VersionInfo(this.revisionId, this.parentRevision, this.size, this.createdAt);
  final String revisionId;
  final String? parentRevision;
  final int size;
  final String createdAt;

  factory VersionInfo.fromJson(Map<String, dynamic> j) => VersionInfo(
        j['revision_id'] as String,
        j['parent_revision'] as String?,
        j['size'] as int? ?? 0,
        j['created_at'] as String? ?? '',
      );
}

class SyncEvent {
  SyncEvent(this.seq, this.kind, this.fileId, this.revisionId);
  final int seq;
  final String kind;
  final String? fileId;
  final String? revisionId;

  factory SyncEvent.fromJson(Map<String, dynamic> j) => SyncEvent(
        j['seq'] as int? ?? 0,
        j['kind'] as String? ?? '',
        j['file_id'] as String?,
        j['revision_id'] as String?,
      );
}

/// Search-only bounds: one listing may contain the entire 100k-node account.
/// The byte cap applies to collected (HTTP-client decoded) response bytes, not
/// just Content-Length. This is a RAM bound, not an encrypted-format change.
const searchListingMaxBodyBytes = 64 * 1024 * 1024;
const searchListingMaxFiles = 100000;

ApiException _searchListingError([int status = 0]) =>
    ApiException(status, 'search_listing', 'Search listing unavailable');

/// Separate lexical scope: capture bytes only, never HTTP clients, sessions,
/// native handles or lifecycle completers. Validation and model construction
/// are inside the worker too. Returned models contain only opaque metadata.
Future<List<RemoteFile>> runSearchListingDecode(List<int> bytes) =>
    Isolate.run(() => _decodeSearchListing(bytes));

List<RemoteFile> _decodeSearchListing(List<int> bytes) {
  try {
    if (bytes.length > searchListingMaxBodyBytes) {
      throw _searchListingError();
    }
    final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final files = body['files'] as List;
    if (files.length > searchListingMaxFiles) throw _searchListingError();
    return files
        .map((file) => RemoteFile.fromJson(file as Map<String, dynamic>))
        .toList();
  } catch (_) {
    // Decoder/type errors can embed response excerpts. Never return those.
    throw _searchListingError();
  }
}

class ApiClient {
  ApiClient({required String baseUrl, this.token})
      : _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), '');

  final String _baseUrl;
  String? token;

  String get baseUrl => _baseUrl;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(String method, String path,
      {Map<String, dynamic>? body, bool raw = false}) async {
    final uri = Uri.parse('$_baseUrl/api/v1$path');
    late http.Response res;
    try {
      final request = http.Request(method, uri)..headers.addAll(_headers);
      if (body != null) request.body = jsonEncode(body);
      final streamed = await request.send().timeout(const Duration(seconds: 30));
      res = await http.Response.fromStream(streamed);
    } on SocketException catch (e) {
      throw ApiException(0, 'network', e.message);
    }
    if (res.statusCode >= 400) {
      String code = 'error';
      String message = res.reasonPhrase ?? 'request failed';
      try {
        final j = jsonDecode(res.body) as Map<String, dynamic>;
        code = j['error'] as String? ?? code;
        message = j['message'] as String? ?? message;
      } catch (_) {}
      throw ApiException(res.statusCode, code, message);
    }
    if (raw) return {'bytes': res.bodyBytes};
    if (res.body.isEmpty) return {};
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$_baseUrl/api/v1$path').replace(queryParameters: query);

  /// Login requires an Argon2id verifier derived by the Rust core.
  Future<Map<String, dynamic>> loginWithVerifier(
    String email,
    String verifier, {
    Map<String, dynamic>? device,
  }) =>
      _send('POST', '/auth/login', body: {
        'email': email,
        'verifier': verifier,
        if (device != null) 'device': device,
      });

  Future<({bool setupRequired, bool registrationAllowed})> setupStatus() async {
    final j = await _send('GET', '/setup/status');
    return (
      setupRequired: j['setup_required'] as bool? ?? false,
      registrationAllowed: j['registration_allowed'] as bool? ?? false,
    );
  }

  Future<String> createToken(String label) async {
    final j = await _send('POST', '/tokens', body: {'label': label});
    return j['token'] as String;
  }

  Future<String> lookupAccountId(String email) async {
    final j = await _send('GET', '/auth/lookup?email=${Uri.encodeQueryComponent(email)}');
    return j['account_id'] as String;
  }

  Future<Map<String, dynamic>> register({
    required String accountId,
    required String email,
    required String verifier,
    required Map<String, dynamic> keyfile,
    Map<String, dynamic>? recoveryKit,
    Map<String, dynamic>? device,
  }) =>
      _send('POST', '/auth/register', body: {
        'account_id': accountId,
        'email': email,
        'verifier': verifier,
        'keyfile': keyfile,
        if (recoveryKit != null) 'recovery_kit': recoveryKit,
        if (device != null) 'device': device,
      });

  Future<void> createFile({
    required String id,
    required String? parentId,
    required String nameEnc,
    required bool isDir,
  }) =>
      _send('POST', '/files', body: {
        'id': id,
        'parent_id': parentId,
        'name_enc': nameEnc,
        'is_dir': isDir,
      });

  /// Create the fixed Global or this-device root once.
  ///
  /// The client must choose `nodeId` before sealing the name, because the
  /// sealed envelope is bound to that ID. A repeat call (retry, reinstall,
  /// second client) returns the existing root instead of creating a duplicate.
  Future<void> bootstrapRoot({
    required String kind,
    required String nodeId,
    required String nameEnc,
  }) =>
      _send('POST', '/roots', body: {
        'kind': kind,
        'node_id': nodeId,
        'name_enc': nameEnc,
      });

  /// Every fixed root of the account, Global first, including stale devices.
  Future<List<AccountRoot>> listRoots() async {
    final j = await _send('GET', '/roots');
    return (j['roots'] as List? ?? [])
        .map((r) => AccountRoot.fromJson(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteFile(String id) =>
      _send('PATCH', '/files/$id', body: {'deleted': true});

  Future<void> setFavorite(String id, bool favorite) =>
      _send('PATCH', '/files/$id', body: {'favorite': favorite});

  Future<void> renameFile(String id, String nameEnc,
          {required String? parentId, required List<RemoteFile> siblings}) =>
      _send('POST', '/files/$id/rename', body: {
        'name_enc': nameEnc,
        'parent_id': parentId,
        'siblings': siblings.map((f) => {'id': f.id, 'name_enc': f.nameEnc}).toList(),
      });

  Future<void> moveFileChecked(RemoteFile source, String? parentId,
          List<RemoteFile> siblings) =>
      _send('POST', '/files/${source.id}/move-checked', body: {
        'parent_id': parentId,
        'source_parent_id': source.parentId,
        'source_name_enc': source.nameEnc,
        'siblings': siblings.map((f) => {'id': f.id, 'name_enc': f.nameEnc}).toList(),
      });

  Future<void> moveFile(String id, String? parentId) =>
      _send('POST', '/files/$id/move', body: {'parent_id': parentId});

  Future<AccountInfo> me() async {
    final j = await _send('GET', '/me');
    final info = AccountInfo.fromJson(j);
    info.devices = (j['devices'] as List? ?? [])
        .map((d) => DeviceInfo.fromJson(d as Map<String, dynamic>))
        .toList();
    return info;
  }

  /// Search-specific bounded transport and worker parsing. Other list callers
  /// keep listFiles' existing response/error behavior. Limits may be lowered
  /// (e.g. for constrained callers/tests), never raised above the hard cap.
  /// The injectable worker is a lifecycle test seam, not a production fallback.
  Future<List<RemoteFile>> listFilesForSearch({
    String? parentId,
    int maxBodyBytes = searchListingMaxBodyBytes,
    Future<List<RemoteFile>> Function(List<int>) decode = runSearchListingDecode,
  }) async {
    if (maxBodyBytes < 1 || maxBodyBytes > searchListingMaxBodyBytes) {
      throw _searchListingError();
    }
    final client = http.Client();
    try {
      final request = http.Request('GET',
          _uri('/files', parentId == null ? null : {'parent_id': parentId}))
        ..headers.addAll(_headers);
      final response =
          await client.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode >= 400) {
        // No response diagnostics (including reason phrases) cross this API.
        throw _searchListingError(response.statusCode);
      }
      if ((response.contentLength ?? 0) > maxBodyBytes) {
        throw _searchListingError();
      }
      final bytes = BytesBuilder(copy: false);
      await for (final chunk
          in response.stream.timeout(const Duration(seconds: 30))) {
        if (chunk.length > maxBodyBytes - bytes.length) {
          throw _searchListingError();
        }
        bytes.add(chunk);
      }
      return await decode(bytes.takeBytes());
    } on ApiException {
      rethrow;
    } catch (_) {
      throw _searchListingError();
    } finally {
      client.close(); // Includes header/body bounds, timeout and parse failures.
    }
  }

  Future<List<RemoteFile>> listFiles({String? parentId}) async {
    final j = await _send('GET', '/files${parentId == null ? '' : '?parent_id=$parentId'}');
    return (j['files'] as List? ?? [])
        .map((f) => RemoteFile.fromJson(f as Map<String, dynamic>))
        .toList();
  }

  Future<List<VersionInfo>> versions(String fileId) async {
    final j = await _send('GET', '/files/$fileId/versions');
    return (j['versions'] as List? ?? [])
        .map((v) => VersionInfo.fromJson(v as Map<String, dynamic>))
        .toList();
  }

  Future<List<DeviceInfo>> devices() async {
    final j = await _send('GET', '/devices');
    return (j['devices'] as List? ?? [])
        .map((d) => DeviceInfo.fromJson(d as Map<String, dynamic>))
        .toList();
  }

  Future<void> revokeDevice(String id) => _send('DELETE', '/devices/$id');

  Future<List<SyncEvent>> eventsSince(int seq) async {
    final j = await _send('GET', '/events?since=$seq');
    return (j['events'] as List? ?? [])
        .map((e) => SyncEvent.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> logout() => _send('POST', '/auth/logout');

  /// Returns the sealed manifest. Only the Rust core can open it.
  Future<List<int>> manifest(String fileId, {String? revision}) async {
    final uri = _uri('/files/$fileId/manifest',
        revision == null ? null : {'revision': revision});
    final res = await http.get(uri, headers: _headers);
    if (res.statusCode >= 400) {
      throw ApiException(res.statusCode, 'manifest', 'cannot fetch manifest');
    }
    return res.bodyBytes;
  }

  Uri articleUrl(String messageId) =>
      _uri('/articles/${Uri.encodeComponent(messageId)}');
}
