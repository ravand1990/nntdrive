import 'dart:io';

import 'package:path/path.dart' as p;

import 'api.dart';
import 'file_rename.dart';
import 'sync_controller.dart';

/// Presence is not a journal/content-integrity claim. Folder-wide activity and
/// errors are explicitly identified as such rather than attributed to one file.
class LocalAvailability {
  const LocalAvailability(this.label, this.explanation,
      {this.path, this.folder, this.relativePath, this.isDirectory = false,
      this.verifiedAtRefresh = false});

  final String label;
  final String explanation;
  final String? path;
  final SyncFolderConfig? folder;
  final String? relativePath;
  final bool isDirectory;
  final bool verifiedAtRefresh;

  LocalAvailability withoutEquality() => LocalAvailability(label, explanation,
      path: path, folder: folder, relativePath: relativePath,
      isDirectory: isDirectory);

  static const unknown = LocalAvailability(
      'Unknown', 'Cannot safely map this entry to a configured sync folder.');

  // A folder's current event is not evidence that its other entries are active.
  // A terminal event also does not establish disk/journal/revision equality.
  bool get _transferring => !isDirectory && label != 'Conflict' &&
      relativePath != null && folder?.running == true &&
      folder?.progress?['path'] == relativePath &&
      folder?.progress?['complete'] == false;

  bool get _failed {
    if (folder?.running != false || relativePath == null || label == 'Conflict') {
      return false;
    }
    final errors = folder?.lastReport?['item_errors'];
    return errors is List && errors.any((error) =>
        error is Map && error['operation'] is String && error['code'] is String &&
        error['paths'] is List && (error['paths'] as List).contains(relativePath));
  }

  String get displayLabel => _transferring ? 'Syncing' : _failed ? 'Error' : label;

  String get displayExplanation => _transferring
      ? 'This file is transferring; content equality and final success are not verified.'
      : _failed
          ? 'An operation involving this exact path failed in the last completed sync attempt. '
              'Refresh or retry sync; current content equality is not verified. $explanation'
          : verifiedAtRefresh && folder?.running != true
              ? 'At the last refresh, freshly hashed local bytes matched the journal baseline and the listed remote revision. Refresh to recheck; this is not a durability guarantee.'
              : explanation;
}

/// The caller supplies a freshly decrypted, unambiguous remote ancestry, from
/// account root through the item. Root matching uses opaque IDs, never names.
Future<LocalAvailability> inspectLocalAvailability({
  required List<({String id, String name})> ancestry,
  required List<SyncFolderConfig> folders,
  required bool isDir,
  bool Function()? cancelled,
}) async {
  void check() {
    if (cancelled?.call() == true) throw StateError('Inspection cancelled');
  }
  check();
  final matches = <(SyncFolderConfig, int)>[];
  for (final folder in folders) {
    final index = ancestry.indexWhere((node) => node.id == folder.remoteRootId);
    if (index >= 0) matches.add((folder, index));
  }
  if (matches.isEmpty) {
    return const LocalAvailability(
        'Not covered', 'No configured sync folder covers this entry.');
  }
  if (matches.length != 1) return LocalAvailability.unknown;
  final (folder, index) = matches.single;
  final components = ancestry.skip(index + 1).map((node) => node.name).toList();
  if (components.isEmpty && !isDir) return LocalAvailability.unknown;
  if (components.any((name) => renameValidationError(name) != null)) {
    return LocalAvailability.unknown;
  }
  final relative = components.join('/');
  if (folder.excluded.any((ex) => relative == ex || relative.startsWith('$ex/'))) {
    return const LocalAvailability(
        'Not covered', 'This entry is excluded from synchronization.');
  }
  try {
    final root = p.normalize(p.absolute(folder.localPath));
    // Reject links, including a symlinked root/ancestor. Do not silently map to
    // another location even if the resulting target is readable.
    if (await FileSystemEntity.type(root, followLinks: false) !=
            FileSystemEntityType.directory ||
        !p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
      return const LocalAvailability(
          'Error', 'The configured sync root is missing or unsafe.');
    }
    var current = root;
    for (var i = 0; i < components.length; i++) {
      check();
      current = p.join(current, components[i]);
      if (!p.isWithin(root, current)) return LocalAvailability.unknown;
      final type = await FileSystemEntity.type(current, followLinks: false);
      check();
      if (type == FileSystemEntityType.notFound) {
        // Only a missing leaf has a validated containing directory. A missing
        // ancestor must not let cached conflict discovery bypass confinement.
        final conflict = !isDir && i == components.length - 1 &&
            await _hasSafeConflictCopy(folder, relative, current);
        return LocalAvailability(conflict ? 'Conflict' : 'Cloud only',
            conflict
                ? 'The original is missing, but a preserved conflict copy exists in its containing directory; review revalidates the pair.'
                : 'No copy exists at the expected synced path.',
            folder: folder, relativePath: relative, isDirectory: isDir);
      }
      final expected = i == components.length - 1 && !isDir
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      final resolved = type == FileSystemEntityType.directory
          ? await Directory(current).resolveSymbolicLinks()
          : type == FileSystemEntityType.file
              ? await File(current).resolveSymbolicLinks()
              : null;
      if (type != expected || resolved == null || !p.equals(resolved, current)) {
        return const LocalAvailability(
            'Error', 'The expected synced path has an unsafe or unexpected type.');
      }
    }
    var conflict = !isDir && folder.conflictFiles.contains(relative);
    if (!isDir && !conflict) {
      conflict = await _hasSafeConflictCopy(folder, relative, current);
    }
    return LocalAvailability(conflict ? 'Conflict' : 'Local',
        conflict
            ? 'A preserved conflict copy was discovered for this file; review revalidates the pair.'
            : 'Present at the expected synced path; content equality is not verified.',
        path: current, folder: folder, relativePath: relative, isDirectory: isDir);
  } on FileSystemException {
    return const LocalAvailability(
        'Error', 'The expected synced path could not be inspected.');
  }
}

// The caller has validated every containing component, without following links.
// Discovery is only a hint: recheck same-directory regular-file presence. This
// establishes a conflict candidate, not journal validity or revision equality.
Future<bool> _hasSafeConflictCopy(
    SyncFolderConfig folder, String relative, String current) async {
  for (final copy in folder.conflictFiles) {
    if (p.posix.dirname(copy) != p.posix.dirname(relative) ||
        originalConflictPath(copy) != relative ||
        copy.split('/').any((part) => renameValidationError(part) != null)) {
      continue;
    }
    final candidate = p.join(p.dirname(current), p.posix.basename(copy));
    if (await FileSystemEntity.type(candidate, followLinks: false) ==
            FileSystemEntityType.file &&
        p.equals(await File(candidate).resolveSymbolicLinks(), candidate)) {
      return true;
    }
  }
  return false;
}

/// Resolve ancestry from fresh listings; never trust the breadcrumb's cached
/// names after another device renames or moves an ancestor. Ambiguous encrypted
/// sibling names fail closed instead of assigning somebody else's local file.
Future<Map<String, LocalAvailability>> inspectBrowserAvailability({
  required List<String> parentIds,
  required List<SyncFolderConfig> folders,
  required Future<List<RemoteFile>> Function(String?) list,
  required String Function(RemoteFile) decrypt,
  required String Function(String) comparisonKey,
  Future<bool> Function(SyncFolderConfig, String, RemoteFile)? verifyFile,
}) async {
  final ancestry = <({String id, String name})>[];
  String? parent;
  for (final id in parentIds) {
    final siblings = await list(parent);
    final entry = siblings.where((node) => node.id == id).firstOrNull;
    if (entry == null || !entry.isDir || entry.parentId != parent) return {};
    final name = _unambiguousNames(siblings, decrypt, comparisonKey)[id];
    if (name == null) return {};
    ancestry.add((id: id, name: name));
    parent = id;
  }
  final entries = await list(parent);
  final names = _unambiguousNames(entries, decrypt, comparisonKey);
  final result = <String, LocalAvailability>{};
  for (final entry in entries) {
    final name = entry.parentId == parent ? names[entry.id] : null;
    var state = name == null
        ? LocalAvailability.unknown
        : await inspectLocalAvailability(
            ancestry: [...ancestry, (id: entry.id, name: name)],
            folders: folders, isDir: entry.isDir);
    if (verifyFile != null && !entry.isDir && entry.currentVersion != null &&
        state.displayLabel == 'Local' && state.folder?.running == false &&
        state.relativePath != null && state.path != null) {
      try {
        if (await verifyFile(state.folder!, state.relativePath!, entry) &&
            !state.folder!.running) {
          state = LocalAvailability(state.label, state.explanation,
              path: state.path, folder: state.folder, relativePath: state.relativePath,
              verifiedAtRefresh: true);
        }
      } catch (_) {
        // Missing/old/corrupt journal or native errors retain presence-only truth.
      }
    }
    result[entry.id] = state;
  }
  return result;
}

Map<String, String> _unambiguousNames(List<RemoteFile> siblings,
    String Function(RemoteFile) decrypt, String Function(String) comparisonKey) {
  final names = <String, String>{};
  final keys = <String, String>{};
  final counts = <String, int>{};
  try {
    for (final sibling in siblings) {
      final name = decrypt(sibling);
      if (renameValidationError(name) != null || names.containsKey(sibling.id)) {
        return {};
      }
      final key = comparisonKey(name);
      names[sibling.id] = name;
      keys[sibling.id] = key;
      counts[key] = (counts[key] ?? 0) + 1;
    }
    names.removeWhere((id, _) => counts[keys[id]] != 1);
    return names;
  } catch (_) {
    return {};
  }
}

/// Revalidate immediately before launching. Only open the containing directory,
/// never execute the file or pass a command through a shell. A hostile concurrent
/// filesystem writer can still race the external file manager after validation.
Future<void> revealLocalAvailability(
    Future<LocalAvailability> Function() revalidate,
    {Future<ProcessResult> Function(String, List<String>)? launch}) async {
  if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    throw StateError('Local reveal is only supported on desktop.');
  }
  final state = await revalidate();
  if (state.path == null) throw StateError('No safe local copy exists.');
  final command = Platform.isWindows
      ? 'explorer.exe'
      : Platform.isMacOS ? 'open' : 'xdg-open';
  final result = await (launch ?? ((cmd, args) => Process.run(cmd, args)))(
      command, [state.isDirectory ? state.path! : p.dirname(state.path!)]);
  if (result.exitCode != 0) throw StateError('Could not open file manager.');
}
