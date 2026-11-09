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
  // Win32 recognizes device names even before an extension and with spaces
  // before that extension. ISO-8859-1 superscript digits are device aliases too.
  final stem = name.split('.').first.trimRight().toUpperCase();
  if (RegExp(r'^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])$')
      .hasMatch(stem)) {
    return 'This name is reserved on Windows.';
  }
  // Dart's UTF-8 encoder substitutes malformed UTF-16. Reject it rather than
  // checking one spelling and sealing a different replacement-character name.
  final units = name.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final unit = units[i];
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (i + 1 == units.length ||
          units[i + 1] < 0xdc00 ||
          units[i + 1] > 0xdfff) {
        return 'Use a valid Unicode filename.';
      }
      i++;
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      return 'Use a valid Unicode filename.';
    }
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

/// Decrypt collision candidates locally, then send only node-bound envelopes.
/// The server compares this complete sibling snapshot while holding the account
/// namespace lock. Concurrent changes require a fresh collision check, not retry
/// of the old request. Legacy unconditional writers remain compatible and can
/// still introduce duplicate names after this operation completes.
Future<void> renameRemoteEntry({
  required ApiClient api,
  required int handle,
  required RemoteFile file,
  required String name,
}) async {
  final invalid = renameValidationError(name);
  if (invalid != null) throw RenameFailure(invalid);
  final bridge = NativeBridge.instance;
  final comparison = bridge.nameCollisionKey(name);
  final siblings = await api.listFiles(parentId: file.parentId);
  if (siblings.length > 4096) {
    throw RenameFailure(
        'This folder is too large for a safe rename (4096 entries maximum).');
  }
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
    if (bridge.nameCollisionKey(siblingName) == comparison) {
      throw RenameFailure(
          'A file or folder with this name already exists. Choose another name.');
    }
  }
  final sealed = bridge.sealName(handle, file.id, name);
  try {
    await api.renameFile(file.id, sealed,
        parentId: file.parentId, siblings: siblings);
  } on ApiException catch (e) {
    if (e.status == 409) {
      throw RenameFailure(
          'This folder changed. Refresh the list and try again.');
    }
    rethrow;
  }
}
