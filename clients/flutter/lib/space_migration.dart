// Migrating sync folders that predate account spaces (#95).
//
// Before the fixed Global and per-device spaces existed, a sync folder's remote
// directory was created directly at the account root. On an existing account
// those folders still sit there: they are synced, but they belong to no space,
// so they are invisible in the account-spaces view and are not part of the
// layout every new client uses.
//
// This module only *detects* them and offers one guarded move into this
// device's space. Nothing is moved automatically: moving a folder is a remote
// change to the user's data, so it stays an explicit action. The move keeps the
// node, its sealed name, every version and its subtree, and the local sync
// entry keeps working because it tracks the remote root node ID, not its path.

import 'account_roots.dart';
import 'api.dart';
import 'file_move.dart';
import 'file_rename.dart';

/// Top-level account folders that are the root of a synced folder but belong
/// to none of the account's fixed spaces.
///
/// Detection uses only opaque node IDs, so it needs no decryption: a candidate
/// must be a directory, must be a configured sync root, and must not itself be
/// one of the fixed roots. An empty root list means the spaces are unknown, in
/// which case nothing is reported rather than guessing.
List<RemoteFile> foldersOutsideSpaces({
  required List<RemoteFile> accountTopLevel,
  required Iterable<AccountRoot> roots,
  required Iterable<String> syncRootIds,
}) {
  if (roots.isEmpty) return const [];
  final fixed = {for (final root in roots) root.nodeId};
  final synced = syncRootIds.toSet();
  final seen = <String>{};
  final found = <RemoteFile>[];
  for (final entry in accountTopLevel) {
    if (!entry.isDir) continue;
    if (fixed.contains(entry.id)) continue;
    if (!synced.contains(entry.id)) continue;
    if (!seen.add(entry.id)) continue;
    found.add(entry);
  }
  found.sort((a, b) => a.id.compareTo(b.id));
  return found;
}

/// The device space a legacy folder can be moved into, or null when this
/// sign-in has no usable device space. Another device's space is never used.
AccountRoot? thisDeviceSpace(List<AccountRoot> roots, String? deviceRootNodeId) {
  if (deviceRootNodeId == null) return null;
  for (final root in roots) {
    if (!root.isGlobal && root.nodeId == deviceRootNodeId) return root;
  }
  return null;
}

/// Move [folder] into this device's space with the same guarded move the file
/// manager uses. Returns a plain-language result for the user; never throws for
/// an expected failure and never deletes or overwrites anything.
Future<String> moveFolderIntoDeviceSpace({
  required ApiClient api,
  required int handle,
  required RemoteFile folder,
  required List<AccountRoot> roots,
  required String? deviceRootNodeId,
}) async {
  final space = thisDeviceSpace(roots, deviceRootNodeId);
  if (space == null) {
    return 'This sign-in has no device space, so the folder stays where it is.';
  }
  final label = accountRootLabel(space);
  try {
    await moveRemoteEntry(
      api: api,
      handle: handle,
      file: folder,
      parentId: space.nodeId,
    );
  } on RenameFailure catch (e) {
    return e.toString();
  } on ApiException catch (e) {
    if (e.status == 0) {
      return 'Could not reach the server. The folder stays where it is; retry later.';
    }
    if (e.status == 401 || e.status == 403) {
      return 'Sign in again to move this folder. Nothing was moved.';
    }
    if (e.status == 404) {
      return 'The folder no longer exists. Refresh and try again.';
    }
    return 'Could not move this folder. Nothing was moved; refresh and retry.';
  }
  return 'Moved into $label. Files, versions and local sync are unchanged.';
}
