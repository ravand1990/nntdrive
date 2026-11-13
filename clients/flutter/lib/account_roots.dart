// Client-side bootstrap of the fixed account roots (#95).
//
// The backend cannot seal a name: sealed names are bound to their node ID as
// authenticated data, so the client generates each node ID, seals the root name
// for that ID, and only then asks the backend to record the root. Bootstrap is
// idempotent — a retry, a reinstall or a second client receives the original
// root instead of creating a duplicate — which is what lets every client agree
// on one Global space and one space per device.

import 'package:uuid/uuid.dart';

import 'api.dart';

/// Sealed, user-visible name for the account-wide space every client shares.
const globalRootName = 'Global';

/// Fallback name when the backend cannot report this device's own name.
const deviceRootFallbackName = 'This device';

/// Seals [name] for [nodeId] in the unlocked session (native core).
typedef RootNameSealer = String Function(String nodeId, String name);

typedef NodeIdFactory = String Function();

String _randomNodeId() => const Uuid().v4();

/// Result of one bootstrap pass: the roots the account now has, plus a
/// plain-language warning when only the this-device space could not be made.
class AccountRootsResult {
  const AccountRootsResult(this.roots, {this.warning, this.deviceRootNodeId});

  final List<AccountRoot> roots;

  /// Set when the device space could not be bootstrapped (for example a
  /// session token that is not device-bound). Global bootstrap still applies.
  final String? warning;

  /// Node ID of *this* device's own fixed space, or null when the account has
  /// none. Sync folders created on this device are placed inside it, so two
  /// devices cannot create the same path at the account root.
  final String? deviceRootNodeId;
}

class AccountRootsService {
  AccountRootsService({
    required this.api,
    required this.sealName,
    NodeIdFactory? newNodeId,
    this.maxBootstrapAttempts = 2,
  }) : newNodeId = newNodeId ?? _randomNodeId {
    if (maxBootstrapAttempts < 1 || maxBootstrapAttempts > 4) {
      throw ArgumentError.value(
          maxBootstrapAttempts, 'maxBootstrapAttempts', 'must be 1..4');
    }
  }

  final ApiClient api;
  final RootNameSealer sealName;
  final NodeIdFactory newNodeId;

  /// A node-ID collision is a bounded retry, never an unbounded loop.
  final int maxBootstrapAttempts;

  /// Ensure both fixed roots exist, then list every root of the account.
  ///
  /// The account is read first: when the server is unreachable this fails once
  /// instead of repeating a request timeout for every bootstrap call, and a
  /// launch that already has its roots sends no writes at all. Global is
  /// created first because every client depends on it. The device space is
  /// best-effort: a token that is not device-bound cannot create one, and that
  /// must not hide the Global space from the user.
  Future<AccountRootsResult> ensure() async {
    final existing = await api.listRoots();
    final device = await _currentDevice();

    if (!existing.any((root) => root.isGlobal)) {
      await _bootstrap('global', globalRootName);
    }
    String? warning;
    final deviceRootExists = device != null &&
        existing
            .any((root) => root.kind == 'device' && root.deviceId == device.id);
    if (!deviceRootExists) {
      try {
        await _bootstrap('device', device?.name ?? deviceRootFallbackName);
      } on ApiException catch (e) {
        if (e.status == 400 || e.status == 403) {
          warning = 'This sign-in cannot create a device space. '
              'The Global space is available.';
        } else {
          rethrow;
        }
      }
    }
    final roots = await api.listRoots();
    return AccountRootsResult(roots,
        warning: warning,
        deviceRootNodeId: _deviceRootNodeId(roots, device?.id));
  }

  /// This device's own space, never another device's. A token without a
  /// current device entry gets no destination rather than a guessed one.
  static String? _deviceRootNodeId(List<AccountRoot> roots, String? deviceId) {
    if (deviceId == null) {
      return null;
    }
    for (final root in roots) {
      if (root.kind == 'device' && root.deviceId == deviceId) {
        return root.nodeId;
      }
    }
    return null;
  }

  /// Re-read the account's roots without creating anything.
  Future<List<AccountRoot>> refresh() => api.listRoots();

  Future<void> _bootstrap(String kind, String name) async {
    ApiException? collision;
    for (var attempt = 0; attempt < maxBootstrapAttempts; attempt++) {
      // The sealed name is bound to this ID: seal it for exactly the ID sent.
      final nodeId = newNodeId();
      final sealed = sealName(nodeId, name);
      try {
        await api.bootstrapRoot(kind: kind, nodeId: nodeId, nameEnc: sealed);
        return;
      } on ApiException catch (e) {
        if (e.status != 409) rethrow;
        // The ID already belongs to another node, or another caller created
        // this root concurrently. A retry re-reads the account and converges.
        collision = e;
      }
    }
    throw collision!;
  }

  Future<({String id, String name})?> _currentDevice() async {
    try {
      final me = await api.me();
      for (final device in me.devices) {
        if (device.current) {
          return (
            id: device.id,
            name: device.name.isEmpty ? deviceRootFallbackName : device.name,
          );
        }
      }
    } catch (_) {
      // The device identity is only needed to tell whether this device already
      // has a space. A failure here must not block bootstrap; a real
      // authorization problem surfaces on the bootstrap call itself.
    }
    return null;
  }
}

/// One-line description of a fixed root for the account-spaces overview.
String accountRootLabel(AccountRoot root) {
  if (root.isGlobal) return globalRootName;
  final name = root.deviceName ?? '';
  return name.isEmpty ? deviceRootFallbackName : name;
}

/// Plain-language availability of a fixed root. Stale roots stay usable; the
/// label is a marker, not a deletion or a sync guarantee.
String accountRootStatus(AccountRoot root) {
  if (root.isGlobal) return 'Shared with every device';
  if (root.deviceRevoked) return 'Device revoked · files remain available';
  if (root.stale) return 'Device offline · files remain available';
  return 'On demand on this account';
}

/// True when [remoteRootId] is the account-wide space every client mirrors.
///
/// A sync entry only knows the remote node ID it mirrors, so this is what tells
/// the sync page that an exclusion affects the shared space rather than a folder
/// that exists on this device alone.
bool remoteRootIsGlobal(String remoteRootId, List<AccountRoot> roots) {
  for (final root in roots) {
    if (root.isGlobal && root.nodeId == remoteRootId) return true;
  }
  return false;
}

String _excludedFolders(int count) =>
    count == 1 ? '1 excluded folder' : '$count excluded folders';

/// Warning for the selective-sync dialog when a folder mirrors Global and some
/// of its paths are excluded.
///
/// Global is only "shared with every device" while it synchronizes whole. An
/// exclusion stops the path in both directions, so the other devices no longer
/// receive it and its remote changes are not applied here. Null means the
/// folder is not Global, or has nothing excluded.
String? globalExclusionWarning({
  required String remoteRootId,
  required List<AccountRoot> roots,
  required List<String> excluded,
}) {
  if (excluded.isEmpty || !remoteRootIsGlobal(remoteRootId, roots)) return null;
  return 'Global is shared with every device, but not all of it synchronizes: '
      '${_excludedFolders(excluded.length)}. Excluded paths stop synchronizing '
      'in both directions, so the other devices no longer receive their changes '
      'and their remote changes are not applied here.';
}

/// Short marker for the folder card, so a partly shared Global is visible
/// without opening the dialog. Same conditions as [globalExclusionWarning].
String? globalExclusionMarker({
  required String remoteRootId,
  required List<AccountRoot> roots,
  required List<String> excluded,
}) {
  if (excluded.isEmpty || !remoteRootIsGlobal(remoteRootId, roots)) return null;
  return 'Not fully shared: ${_excludedFolders(excluded.length)}';
}
