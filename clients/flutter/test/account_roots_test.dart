import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_roots.dart';
import 'package:nntdrive/api.dart';

/// In-memory stand-in for the backend `/roots` API. It keeps the same
/// idempotent shape as the real server: a repeat call returns the existing
/// root, and a node ID that already belongs to another node is a 409.
class FakeRootsApi extends ApiClient {
  FakeRootsApi() : super(baseUrl: 'http://unused');

  final List<({String kind, String nodeId, String nameEnc})> bootstraps = [];
  final List<AccountRoot> roots = [];
  final Set<String> takenIds = {};
  final Map<String, String> deviceNames = {
    'current': 'Workstation',
  };

  /// Optional per-kind failures; used for the refusal and error paths.
  int? globalFailureStatus;
  int? deviceFailureStatus;
  int? listFailureStatus;
  bool meFails = false;
  int listCalls = 0;

  @override
  Future<void> bootstrapRoot({
    required String kind,
    required String nodeId,
    required String nameEnc,
  }) async {
    bootstraps.add((kind: kind, nodeId: nodeId, nameEnc: nameEnc));
    final failure =
        kind == 'global' ? globalFailureStatus : deviceFailureStatus;
    if (failure != null) {
      throw ApiException(failure, 'error', 'bootstrap failed');
    }
    if (takenIds.contains(nodeId)) {
      throw ApiException(409, 'conflict', 'node_id already exists');
    }
    final deviceId = kind == 'device' ? 'device-1' : null;
    if (roots.any((r) => r.kind == kind && r.deviceId == deviceId)) return;
    roots.add(AccountRoot(
      rootId: 'root-${roots.length}',
      kind: kind,
      nodeId: nodeId,
      nameEnc: nameEnc,
      deviceId: deviceId,
    ));
  }

  @override
  Future<List<AccountRoot>> listRoots() async {
    listCalls++;
    if (listFailureStatus != null) {
      throw ApiException(listFailureStatus!, 'network', 'list failed');
    }
    return List<AccountRoot>.of(roots);
  }

  @override
  Future<AccountInfo> me() async {
    if (meFails) throw ApiException(500, 'error', 'me failed');
    final info = AccountInfo('account', 'user@example.test', 'User', false,
        null, 0);
    info.devices = [
      DeviceInfo('device-1', deviceNames['current'] ?? '', 'linux', false, true),
      DeviceInfo('device-2', 'Tablet', 'android', false, false),
    ];
    return info;
  }
}

String openSealed(String sealed) =>
    utf8.decode(base64Decode(sealed)); // test envelopes: "name|nodeId"

void main() {
  late FakeRootsApi api;
  late List<String> sealed;
  var counter = 0;

  setUp(() {
    api = FakeRootsApi();
    sealed = [];
    counter = 0;
  });

  AccountRootsService service() => AccountRootsService(
        api: api,
        newNodeId: () => 'id-${++counter}',
        sealName: (nodeId, name) {
          final envelope = base64Encode(utf8.encode('$name|$nodeId'));
          sealed.add(envelope);
          return envelope;
        },
      );

  test('bootstraps Global then this device with names sealed for their IDs',
      () async {
    final result = await service().ensure();

    expect(result.warning, isNull);
    expect(result.roots.map((r) => r.kind), ['global', 'device']);
    expect(api.bootstraps, hasLength(2));
    // The envelope must be bound to exactly the ID that was sent, or no client
    // could ever open the stored name.
    expect(api.bootstraps[0].nodeId, 'id-1');
    expect(openSealed(api.bootstraps[0].nameEnc), 'Global|id-1');
    expect(api.bootstraps[1].nodeId, 'id-2');
    expect(openSealed(api.bootstraps[1].nameEnc), 'Workstation|id-2');
  });

  test('a repeat launch reads the roots instead of writing again', () async {
    final first = await service().ensure();
    final second = await service().ensure();

    expect(second.roots, hasLength(2));
    expect(second.roots.map((r) => r.rootId),
        first.roots.map((r) => r.rootId));
    expect(api.roots, hasLength(2));
    // One Global and one device bootstrap in total across both launches.
    expect(api.bootstraps, hasLength(2));
  });

  test('another client\'s Global is reused and only this device is created',
      () async {
    api.roots.addAll([
      AccountRoot(
          rootId: 'other-global',
          kind: 'global',
          nodeId: 'someone-else-1',
          nameEnc: 'opaque'),
      AccountRoot(
          rootId: 'other-device',
          kind: 'device',
          nodeId: 'someone-else-2',
          nameEnc: 'opaque',
          deviceId: 'device-2'),
    ]);

    final result = await service().ensure();

    // The other device's space is not this device's space.
    expect(result.roots.map((r) => r.rootId),
        ['other-global', 'other-device', 'root-2']);
    expect(api.bootstraps.map((b) => b.kind), ['device']);
  });

  test('an unreachable server fails before any bootstrap write', () async {
    api.listFailureStatus = 0;

    await expectLater(service().ensure(),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 0)));
    expect(api.bootstraps, isEmpty);
  });

  test('a taken node ID retries once with a fresh client-chosen ID', () async {
    api.takenIds.add('id-1');

    final result = await service().ensure();

    expect(result.roots, hasLength(2));
    expect(api.bootstraps.map((b) => b.nodeId), ['id-1', 'id-2', 'id-3']);
    expect(openSealed(api.bootstraps[1].nameEnc), 'Global|id-2');
  });

  test('a persistent collision stops after the bounded attempts', () async {
    api.takenIds.addAll(['id-1', 'id-2', 'id-3']);

    await expectLater(
        service().ensure(), throwsA(isA<ApiException>()));

    // Two attempts for Global only; nothing partial was created.
    expect(api.bootstraps.map((b) => b.nodeId), ['id-1', 'id-2']);
    expect(api.roots, isEmpty);
  });

  test('a device-space refusal still reports the Global space', () async {
    // Global succeeds, then the device bootstrap is refused for a token that
    // is not device-bound.
    api.deviceFailureStatus = 400;

    final result = await service().ensure();

    expect(result.roots.map((r) => r.kind), ['global']);
    expect(result.warning, contains('Global space'));
  });

  test('a non-409 failure is surfaced, not swallowed', () async {
    api.globalFailureStatus = 500;

    await expectLater(service().ensure(),
        throwsA(isA<ApiException>().having((e) => e.status, 'status', 500)));
    expect(api.roots, isEmpty);
  });

  test('the device name falls back without blocking bootstrap', () async {
    api.meFails = true;

    final result = await service().ensure();

    expect(result.roots, hasLength(2));
    expect(openSealed(api.bootstraps[1].nameEnc), 'This device|id-2');
  });

  test('the sealed name is never sent for a different node ID', () async {
    // Guard the binding invariant directly: every envelope's ID suffix must
    // equal the node_id in the same request.
    await service().ensure();
    for (final request in api.bootstraps) {
      expect(openSealed(request.nameEnc), endsWith('|${request.nodeId}'));
    }
  });
}
