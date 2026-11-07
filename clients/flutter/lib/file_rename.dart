import 'dart:convert';
import 'api.dart';
import 'native.dart';

/// A single portable path component, never a path supplied to the filesystem.
String? renameValidationError(String name) {
  if (name.isEmpty || name.trim() != name || name.endsWith('.')) {
    return 'Enter a name without leading/trailing spaces or a trailing dot.';
  }
  if (name == '.' ||
      name == '..' ||
      name.contains(RegExp(r'[<>:"/\\|?*\x00-\x1f\x7f]'))) {
    return 'Use a single filename without path separators or reserved characters.';
  }
  final stem = name.split('.').first.toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$').hasMatch(stem)) {
    return 'This name is reserved on Windows.';
  }
  if (utf8.encode(name).length > 255) {
    return 'Use a shorter name (at most 255 UTF-8 bytes).';
  }
  return null;
}

class RenameFailure implements Exception {
  RenameFailure(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Decrypt collision candidates locally, then send only a node-bound envelope.
/// The existing API has no atomic encrypted-name uniqueness/CAS contract: this
/// preflight is deliberately not advertised as protection against other devices
/// racing the final PATCH. No existing entry/content is overwritten.
Future<void> renameRemoteEntry({
  required ApiClient api,
  required int handle,
  required RemoteFile file,
  required String name,
}) async {
  final invalid = renameValidationError(name);
  if (invalid != null) throw RenameFailure(invalid);
  final bridge = NativeBridge.instance;
  final siblings = await api.listFiles(parentId: file.parentId);
  final current = siblings.where((entry) => entry.id == file.id).firstOrNull;
  if (current == null ||
      current.revision != file.revision ||
      current.nameEnc != file.nameEnc) {
    throw RenameFailure('This entry changed. Refresh the list and try again.');
  }
  for (final sibling in siblings) {
    if (sibling.id == file.id) continue;
    String siblingName;
    try {
      siblingName = bridge.openName(handle, sibling.id, sibling.nameEnc);
    } catch (_) {
      throw RenameFailure(
          'Cannot check all names in this folder. Rename cancelled.');
    }
    if (siblingName.toLowerCase() == name.toLowerCase()) {
      throw RenameFailure(
          'A file or folder with this name already exists. Choose another name.');
    }
  }
  final sealed = bridge.sealName(handle, file.id, name);
  await api.renameFile(file.id, sealed);
}
