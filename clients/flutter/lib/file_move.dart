import 'api.dart';
import 'file_rename.dart';
import 'native.dart';

/// Keeps node-bound encrypted names and all content revisions unchanged.
Future<void> moveRemoteEntry({
  required ApiClient api,
  required int handle,
  required RemoteFile file,
  required String? parentId,
}) async {
  final bridge = NativeBridge.instance;
  final name = bridge.openName(handle, file.id, file.nameEnc);
  if (renameValidationError(name) != null) {
    throw RenameFailure('This entry has an unsafe name. Rename it first.');
  }
  final comparison = bridge.nameCollisionKey(name);
  if (parentId == file.id) throw RenameFailure('Choose a different folder.');
  if (parentId == file.parentId) return;
  final siblings = await api.listFiles(parentId: parentId);
  if (siblings.length > 4096) {
    throw RenameFailure('This folder is too large for a safe move.');
  }
  for (final sibling in siblings) {
    String other;
    try {
      other = bridge.openName(handle, sibling.id, sibling.nameEnc);
    } catch (_) {
      throw RenameFailure('Cannot check destination names. Move cancelled.');
    }
    if (bridge.nameCollisionKey(other) == comparison) {
      throw RenameFailure('A file or folder with this name already exists. Rename the source or choose another folder.');
    }
  }
  try {
    await api.moveFileChecked(file, parentId, siblings);
  } on ApiException catch (e) {
    if (e.status == 409) {
      throw RenameFailure('The source or destination changed. Refresh and try again.');
    }
    rethrow;
  }
}
