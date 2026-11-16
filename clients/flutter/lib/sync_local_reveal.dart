import 'dart:io';

import 'package:path/path.dart' as p;

import 'file_rename.dart';
import 'local_availability.dart';
import 'sync_controller.dart';

/// Inspect a local-only overview path without inventing remote ancestry or
/// consulting exclusions. Reveal does not synchronize or verify content.
/// Pass a fresh call to this helper to [revealLocalAvailability] at click time;
/// filesystem inspection cannot prevent a later hostile file-manager race.
Future<LocalAvailability> inspectSyncLocalPath({
  required SyncFolderConfig folder,
  required String relativePath,
  required bool isDirectory,
}) async {
  const unavailable = LocalAvailability(
      'Unavailable', 'No safe local copy is available at the expected path.');
  if (folder.localPath.isEmpty ||
      p.posix.isAbsolute(relativePath) ||
      p.windows.isAbsolute(relativePath) ||
      relativePath.contains('\\') ||
      (relativePath.isEmpty && !isDirectory)) {
    return unavailable;
  }
  final components =
      relativePath.isEmpty ? <String>[] : relativePath.split('/');
  if (components.any((part) => renameValidationError(part) != null)) {
    return unavailable;
  }

  try {
    final root = p.normalize(p.absolute(folder.localPath));
    // Inspect every ancestor explicitly, including the root itself. Canonical
    // equality also fails closed if a component changes during inspection.
    var ancestor = root;
    while (true) {
      if (await FileSystemEntity.type(ancestor, followLinks: false) !=
              FileSystemEntityType.directory ||
          !p.equals(
              await Directory(ancestor).resolveSymbolicLinks(), ancestor)) {
        return unavailable;
      }
      final parent = p.dirname(ancestor);
      if (p.equals(parent, ancestor)) break;
      ancestor = parent;
    }

    var current = root;
    for (var i = 0; i < components.length; i++) {
      current = p.join(current, components[i]);
      if (!p.isWithin(root, current)) return unavailable;
      final expected = i == components.length - 1 && !isDirectory
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type != expected) return unavailable;
      final resolved = type == FileSystemEntityType.directory
          ? await Directory(current).resolveSymbolicLinks()
          : await File(current).resolveSymbolicLinks();
      if (!p.equals(resolved, current)) return unavailable;
    }
    return LocalAvailability(
        'Local', 'Present locally; content equality is not verified.',
        path: current,
        folder: folder,
        relativePath: relativePath,
        isDirectory: isDirectory);
  } on FileSystemException {
    return unavailable;
  } on ArgumentError {
    return unavailable;
  }
}
