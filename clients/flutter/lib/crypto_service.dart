// The cryptographic bridge to the shared Rust engine.
//
// NNTDrive deliberately does not reimplement cryptography in Dart. The planned
// bridge exposes (over flutter_rust_bridge or a C ABI):
//
//   derive_auth_verifier(password, account_id) -> String
//   unlock_keyfile(keyfile_json, password) -> KeyHandle
//   enroll_device(keyfile_json, password, device_secret) -> SealedKey
//   prepare_chunk(key_handle, plaintext) -> PreparedChunk (ciphertext only)
//   seal_manifest(key_handle, file_id, revision_id, manifest_json) -> bytes
//   sync_start(config_json) -> Stream<SyncEvent>
//
// Until that exists, this class throws UnsupportedError. The UI disables all
// content operations rather than pretending to encrypt in Dart.

class CryptoUnavailable implements Exception {
  const CryptoUnavailable(this.message);
  final String message;
  @override
  String toString() => message;
}

abstract class CryptoService {
  Future<String> deriveAuthVerifier({required String password, required String accountId});
  Future<void> unlockKeyfile({required String keyfileJson, required String password});
  Future<List<int>> sealManifest({
    required String fileId,
    required String revisionId,
    required List<int> manifestJson,
  });
  Future<void> startSync();
  Future<void> stopSync();
}

class UnavailableCryptoService implements CryptoService {
  const UnavailableCryptoService();

  Never _unavailable() => throw const CryptoUnavailable(
        'The native Rust cryptography bridge is not built into this client yet. '
        'Encryption, login (password verifier) and synchronization are disabled. '
        'See docs/CLIENTS.md.',
      );

  @override
  Future<String> deriveAuthVerifier({required String password, required String accountId}) async =>
      _unavailable();

  @override
  Future<void> unlockKeyfile({required String keyfileJson, required String password}) async =>
      _unavailable();

  @override
  Future<List<int>> sealManifest({
    required String fileId,
    required String revisionId,
    required List<int> manifestJson,
  }) async =>
      _unavailable();

  @override
  Future<void> startSync() async => _unavailable();

  @override
  Future<void> stopSync() async => _unavailable();
}

/// Set by the platform build once the Rust bridge is linked.
CryptoService cryptoService = const UnavailableCryptoService();
