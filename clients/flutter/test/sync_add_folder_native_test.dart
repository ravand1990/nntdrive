import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/native.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal loopback stand-in for the backend endpoints the client sync engine
/// uses for one folder upload: node listing/create, chunk lookup/publish and
/// version commit plus the sealed-manifest read used for hash comparison.
///
/// It stores exactly the ciphertext the client posts. The test therefore proves
/// the real native engine encrypted and committed the file, not that a fixture
/// already contained it.
class _FakeBackend {
  _FakeBackend(this.deviceRoot);

  final String deviceRoot;
  final List<String> requests = [];
  final List<String> unexpected = [];
  final Map<String, Map<String, dynamic>> nodes = {};
  final Map<String, Map<String, dynamic>> chunks = {};
  final List<Map<String, dynamic>> commits = [];

  List<Map<String, dynamic>> childrenOf(String? parent) => nodes.values
      .where((n) => n['parent_id'] == parent && n['deleted'] != true)
      .map((n) => <String, dynamic>{
            'id': n['id'],
            'parent_id': n['parent_id'],
            'name_enc': n['name_enc'],
            'is_dir': n['is_dir'],
            'size': n['size'] ?? 0,
            'favorite': false,
            'revision': n['revision'] ?? 0,
            'current_version': n['current_version'],
          })
      .toList();

  Future<void> handle(HttpRequest request) async {
    final path = request.uri.path;
    requests.add('${request.method} $path');
    try {
      if (request.method == 'GET' && path == '/api/v1/files') {
        final parent = request.uri.queryParameters['parent_id'];
        return await _json(request, {'files': childrenOf(parent)});
      }
      if (request.method == 'POST' && path == '/api/v1/files') {
        final body = await _body(request);
        final id = body['id'] as String;
        nodes[id] = <String, dynamic>{
          'id': id,
          'parent_id': body['parent_id'] as String?,
          'name_enc': body['name_enc'] as String,
          'is_dir': body['is_dir'] == true,
          'size': 0,
          'current_version': null,
        };
        return await _json(request, {'id': id}, status: 201);
      }
      final fileMatch = RegExp(r'^/api/v1/files/([^/]+)$').firstMatch(path);
      if (fileMatch != null && request.method == 'PATCH') {
        final body = await _body(request);
        final node = nodes[fileMatch.group(1)];
        if (node != null && body['deleted'] == true) node['deleted'] = true;
        return await _json(request, const {});
      }
      if (request.method == 'GET' && path == '/api/v1/chunks/lookup') {
        // Deduplication is off in this fixture: every chunk is published and
        // stored so the test can assert on the uploaded ciphertext.
        request.response.statusCode = 404;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'message': 'chunk not found'}));
        await request.response.close();
        return;
      }
      if (request.method == 'POST' && path == '/api/v1/chunks') {
        final body = await _body(request);
        final ciphertext = base64Decode(body['ciphertext'] as String);
        final id = body['chunk_id'] as String;
        chunks[id] = body;
        final entry = <String, dynamic>{
          'id': id,
          'index': body['index'],
          'offset': body['offset'],
          'plaintext_len': body['plaintext_len'],
          'plaintext_hash': body['plaintext_hash'],
          'ciphertext_len': ciphertext.length,
          // ChunkEntry serializes the compression enum by name, while the
          // publish request sends its numeric value.
          'compression': body['compression'] == 1 ? 'Zstd' : 'None',
          'stripes': [
            {
              'id': _uuid('stripe-$id'),
              'index': 0,
              'data_shards': 1,
              'parity_shards': 1,
              'shard_len': ciphertext.length,
              'ciphertext_len': ciphertext.length,
              // Manifest validation requires one hash per shard. This fixture
              // only reads the manifest back, so the parity hash is a
              // placeholder for a shard this test never reconstructs.
              'shard_hashes': [
                sha256.convert(ciphertext).toString(),
                sha256.convert([...ciphertext, 0]).toString(),
              ],
            }
          ],
        };
        return await _json(request, {'chunk': entry}, status: 201);
      }
      final manifestMatch =
          RegExp(r'^/api/v1/files/([^/]+)/manifest$').firstMatch(path);
      if (manifestMatch != null && request.method == 'GET') {
        final node = nodes[manifestMatch.group(1)];
        final revision = request.uri.queryParameters['revision'];
        final sealed = node?['manifests']?[revision] as String?;
        if (sealed == null) {
          return await _error(request, 404, 'manifest not found');
        }
        request.response.headers.set('x-nntdrive-revision', revision!);
        request.response.add(base64Decode(sealed));
        await request.response.close();
        return;
      }
      final versionsMatch =
          RegExp(r'^/api/v1/files/([^/]+)/versions$').firstMatch(path);
      if (versionsMatch != null && request.method == 'POST') {
        final body = await _body(request);
        final node = nodes[versionsMatch.group(1)];
        if (node == null) return await _error(request, 404, 'file not found');
        // The commit body carries no file id; the request path does.
        commits.add({...body, 'file_id': versionsMatch.group(1)});
        final revisionId = body['revision_id'] as String;
        final manifests = (node['manifests'] ??= <String, dynamic>{})
            as Map<String, dynamic>;
        manifests[revisionId] = body['sealed_manifest'];
        node['current_version'] = revisionId;
        node['size'] = body['size'];
        node['revision'] = (node['revision'] as int? ?? 0) + 1;
        return await _json(request, {'revision_id': revisionId}, status: 201);
      }
      unexpected.add('${request.method} $path');
      return await _error(request, 404, 'unexpected fixture request');
    } catch (e) {
      unexpected.add('${request.method} $path threw $e');
      return await _error(request, 500, 'fixture error');
    }
  }

  Map<String, dynamic> get folderNode => nodes.values
      .firstWhere((n) => n['parent_id'] == deviceRoot && n['is_dir'] == true);

  Map<String, dynamic> get fileNode => nodes.values
      .firstWhere((n) => n['is_dir'] == false && n['deleted'] != true);

  Future<Map<String, dynamic>> _body(HttpRequest request) async =>
      jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, dynamic>;

  Future<void> _json(HttpRequest request, Object body,
      {int status = 200}) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _error(HttpRequest request, int status, String message) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'message': message}));
    await request.response.close();
  }

  static String _uuid(String seed) {
    final hex = sha256.convert(utf8.encode(seed)).toString();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // One real loopback server serves the native engine; a widget-test HTTP
  // override would answer every request with a synthetic 400.
  HttpOverrides.global = null;
  late Directory state;
  late Directory local;
  late HttpServer server;
  late _FakeBackend backend;
  late int handle;
  final bridge = NativeBridge.instance;
  const deviceRoot = '11111111-1111-4111-8111-111111111111';

  setUp(() async {
    state = await Directory.systemTemp.createTemp('add-sync-native-');
    local = await Directory('${state.path}/documents').create();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => state.path);
    backend = _FakeBackend(deviceRoot);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(backend.handle);
    const password = 'add folder sync fixture password';
    final account = bridge.generateAccount(password);
    handle = bridge.unlock(jsonEncode(account['keyfile']), password)['handle']
        as int;
  });

  tearDown(() async {
    await bridge.drainSession(handle);
    bridge.lock(handle);
    await server.close(force: true);
    await state.delete(recursive: true);
  });

  test('adding a folder uploads its files and the next round is a no-op',
      () async {
    final content = utf8.encode('hello from the add-folder regression');
    final source = File('${local.path}/notes.txt');
    await source.writeAsBytes(content);

    final api = ApiClient(baseUrl: 'http://127.0.0.1:${server.port}');
    final sync = SyncController(
      server: api.baseUrl,
      token: 'fixture-token',
      handle: handle,
      api: api,
      rootsLoader: () async => AccountRootsResult(
        [
          AccountRoot(
            rootId: 'root-device',
            kind: 'device',
            nodeId: deviceRoot,
            nameEnc: '',
          )
        ],
        deviceRootNodeId: deviceRoot,
      ),
    );
    addTearDown(sync.dispose);

    await sync.load();
    expect(sync.rootsError, isNull);
    expect(sync.deviceRootNodeId, deviceRoot);

    expect(await sync.addFolder(local.path), isTrue,
        reason: sync.lastStatus);
    expect(sync.folders, hasLength(1));
    final folder = sync.folders.single;
    expect(folder.lastError, isNull);
    expect(folder.lastReport?['uploaded'], 1);
    expect(folder.lastReport?['errors'], isEmpty);

    // The remote folder was created inside this device's space.
    expect(backend.folderNode['name_enc'], isNotEmpty);
    // Exactly one revision was committed for the local file, with its size.
    expect(backend.commits, hasLength(1));
    expect(backend.commits.single['size'], content.length);
    expect(backend.commits.single['file_id'], backend.fileNode['id']);
    expect(backend.commits.single['chunk_ids'], hasLength(1));
    // The published chunk is real ciphertext, not the plaintext bytes.
    final chunk = backend.chunks.values.single;
    final ciphertext = base64Decode(chunk['ciphertext'] as String);
    expect(ciphertext, isNotEmpty);
    expect(ciphertext, isNot(equals(content)));

    // A second round reconciles from the journal and the sealed manifest
    // instead of uploading again.
    final commitsBefore = backend.commits.length;
    final again = await sync.syncFolder(folder);
    expect(again, isNotNull);
    expect(again!['uploaded'], 0, reason: '${again['errors']}');
    expect(again['downloaded'], 0);
    expect(again['errors'], isEmpty);
    expect(backend.commits, hasLength(commitsBefore));
    expect(File('${state.path}/sync/${folder.id}.sqlite').existsSync(), isTrue);
    // The journal holds a usable baseline row for the synced file: equality is
    // answered from the stored row, not only re-derived from the remote
    // manifest. Without that row the next launch cannot skip the file.
    final remote = (await api.listFiles(parentId: folder.remoteRootId))
        .singleWhere((f) => !f.isDir);
    expect(await sync.fileMatches(folder, 'notes.txt', remote), isTrue);
    expect(await source.readAsBytes(), content);
    expect(backend.unexpected, isEmpty,
        reason: 'unexpected fixture requests: ${backend.unexpected}');
  });
}
