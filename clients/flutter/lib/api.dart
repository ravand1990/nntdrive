// Typed client for the NNTDrive backend.
//
// All content sent through this client is ciphertext. Encryption, chunking,
// erasure coding and the sync engine live in the Rust core; until the native
// bridge (see crypto_service.dart) is built, content operations are disabled.

import 'dart:convert';
import 'dart:io';

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
  RemoteFile(this.id, this.parentId, this.nameEnc, this.isDir, this.size, this.favorite, this.revision);
  final String id;
  final String? parentId;
  final String nameEnc; // sealed bytes, base64
  final bool isDir;
  final int size;
  final bool favorite;
  final int revision;

  factory RemoteFile.fromJson(Map<String, dynamic> j) => RemoteFile(
        j['id'] as String,
        j['parent_id'] as String?,
        j['name_enc'] as String? ?? '',
        j['is_dir'] as bool? ?? false,
        j['size'] as int? ?? 0,
        j['favorite'] as bool? ?? false,
        j['revision'] as int? ?? 0,
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

class ApiClient {
  ApiClient({required String baseUrl, String? token})
      : _baseUrl = baseUrl.replaceAll(RegExp(r'/+$'), ''),
        _token = token;

  final String _baseUrl;
  String? _token;

  String get baseUrl => _baseUrl;
  String? get token => _token;
  set token(String? value) => _token = value;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (_token != null) 'authorization': 'Bearer $_token',
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

  /// Login requires an Argon2id verifier derived by the Rust core. That bridge
  /// is not shipped yet, so only token login is usable in this scaffold.
  Future<Map<String, dynamic>> loginWithVerifier(String email, String verifier) =>
      _send('POST', '/auth/login', body: {'email': email, 'verifier': verifier});

  Future<AccountInfo> me() async {
    final j = await _send('GET', '/me');
    final info = AccountInfo.fromJson(j);
    info.devices = (j['devices'] as List? ?? [])
        .map((d) => DeviceInfo.fromJson(d as Map<String, dynamic>))
        .toList();
    return info;
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

  Future<Uri> articleUrl(String messageId) =>
      _uri('/articles/${Uri.encodeComponent(messageId)}');
}
