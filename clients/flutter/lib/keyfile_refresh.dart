import 'dart:async';
import 'dart:convert';

import 'api.dart';

/// How long an unlock waits for the server's published keyfile before it
/// continues with the copy this device already holds.
const keyfileRefreshTimeout = Duration(seconds: 5);

/// The account id and AMK epoch a password-wrapped keyfile claims.
///
/// Only these two plaintext fields are inspected; the wrapped key material is
/// never opened here.
({String accountId, int epoch})? keyfileEpoch(String json) {
  try {
    final value = jsonDecode(json);
    if (value is! Map<String, dynamic>) return null;
    final accountId = value['account_id'];
    final epoch = value['epoch'];
    if (accountId is! String || epoch is! int) return null;
    return (accountId: accountId, epoch: epoch);
  } catch (_) {
    return null;
  }
}

/// Picks the keyfile to unlock with: the server's published copy when it is
/// genuinely newer for the same account, otherwise the stored copy.
///
/// Another device may rotate the account master key and publish a keyfile that
/// still carries the previous epochs. Unlocking that newer copy is what keeps
/// revisions written before the rotation readable. The keyfile stays
/// password-wrapped and only its account id and epoch are compared, so no key
/// material leaves the device. A failed, refused or foreign response keeps the
/// stored copy, so an offline start still unlocks.
Future<String> newestKeyfileJson({
  required ApiClient api,
  required String storedJson,
  required String accountId,
  Duration timeout = keyfileRefreshTimeout,
}) async {
  final stored = keyfileEpoch(storedJson);
  if (stored == null || stored.accountId != accountId) return storedJson;
  Map<String, dynamic>? published;
  try {
    published = await api.keyfile().timeout(timeout);
  } catch (_) {
    return storedJson;
  }
  if (published == null) return storedJson;
  final candidate = jsonEncode(published);
  final fields = keyfileEpoch(candidate);
  if (fields == null || fields.accountId != accountId) return storedJson;
  return fields.epoch > stored.epoch ? candidate : storedJson;
}
