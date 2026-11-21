import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/keyfile_refresh.dart';

class _KeyfileApi extends ApiClient {
  _KeyfileApi(this.result, {this.offline = false}) : super(baseUrl: 'http://unused');

  final Map<String, dynamic>? result;
  final bool offline;
  int calls = 0;

  @override
  Future<Map<String, dynamic>?> keyfile() async {
    calls++;
    if (offline) throw ApiException(0, 'network', 'offline');
    return result;
  }
}

String keyfileJson(String accountId, int epoch) => jsonEncode({
      'account_id': accountId,
      'epoch': epoch,
      'wrapped_master_key': 'opaque-wrapped-key',
      'kdf': {'salt': 'opaque'},
    });

const account = '0b9e6b0e-6d3e-4c2a-9c1e-2b1c0d1e2f30';

void main() {
  test('adopts a newer published keyfile for the same account', () async {
    final published = keyfileJson(account, 1);
    final api = _KeyfileApi(jsonDecode(published) as Map<String, dynamic>);
    final chosen = await newestKeyfileJson(
      api: api,
      storedJson: keyfileJson(account, 0),
      accountId: account,
    );
    expect(api.calls, 1);
    expect(keyfileEpoch(chosen), (accountId: account, epoch: 1));
  });

  test('keeps the stored keyfile when the published one is not newer', () async {
    for (final epoch in [0, 0]) {
      final stored = keyfileJson(account, epoch);
      final api = _KeyfileApi(jsonDecode(stored) as Map<String, dynamic>);
      expect(
        await newestKeyfileJson(api: api, storedJson: stored, accountId: account),
        stored,
      );
    }
    final stored = keyfileJson(account, 2);
    final older = _KeyfileApi(jsonDecode(keyfileJson(account, 1)) as Map<String, dynamic>);
    expect(
      await newestKeyfileJson(api: older, storedJson: stored, accountId: account),
      stored,
    );
  });

  test('refuses a published keyfile for a different account', () async {
    final stored = keyfileJson(account, 0);
    final foreign = _KeyfileApi(
        jsonDecode(keyfileJson('11111111-1111-4111-8111-111111111111', 5))
            as Map<String, dynamic>);
    expect(
      await newestKeyfileJson(api: foreign, storedJson: stored, accountId: account),
      stored,
    );
  });

  test('keeps the stored keyfile when the fetch fails or returns nothing', () async {
    final stored = keyfileJson(account, 0);
    expect(
      await newestKeyfileJson(
          api: _KeyfileApi(null, offline: true), storedJson: stored, accountId: account),
      stored,
    );
    expect(
      await newestKeyfileJson(
          api: _KeyfileApi(null), storedJson: stored, accountId: account),
      stored,
    );
  });

  test('keeps the stored keyfile when it cannot be parsed', () async {
    final published = _KeyfileApi(
        jsonDecode(keyfileJson(account, 4)) as Map<String, dynamic>);
    expect(
      await newestKeyfileJson(
          api: published, storedJson: 'not a keyfile', accountId: account),
      'not a keyfile',
    );
    expect(published.calls, 0, reason: 'an unusable local keyfile is not replaced');
  });

  test('keyfileEpoch reads only the account id and epoch', () {
    expect(keyfileEpoch(keyfileJson(account, 3)), (accountId: account, epoch: 3));
    expect(keyfileEpoch('{"account_id":"$account"}'), isNull);
    expect(keyfileEpoch('{"epoch":1}'), isNull);
    expect(keyfileEpoch('[]'), isNull);
    expect(keyfileEpoch(''), isNull);
  });
}
