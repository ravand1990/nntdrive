import 'dart:convert';

import 'account_search.dart';
import 'file_rename.dart';
import 'local_availability.dart';
import 'sync_controller.dart';

/// No HTTP, re-decryption, journal equality, paths or diagnostics in the result.
/// The complete authenticated index supplies sibling/ancestor evidence. Only
/// scalar statuses are later copied into immutable query-worker entries.
Future<Map<String, SearchStatus>> inspectSearchStatuses({
  required Map<String, SearchEntry> snapshot,
  required List<SyncFolderConfig> folders,
  required String Function(String) comparisonKey,
  required bool Function() cancelled,
}) async {
  void check() {
    if (cancelled()) throw const SearchUnavailable();
  }

  check();
  if (snapshot.length > 100000) throw const SearchUnavailable();
  // Freeze controller evidence before the first await. Never retain mutable
  // progress/reports across inspections or send controller objects to workers.
  final roots = folders.map((folder) {
    final copy = SyncFolderConfig.fromJson(
        jsonDecode(jsonEncode(folder.toJson())) as Map<String, dynamic>);
    copy.conflictFiles = List.of(folder.conflictFiles);
    copy.running = folder.running;
    copy.progress = folder.progress == null ? null : Map.of(folder.progress!);
    return copy;
  }).toList();
  final keys = <String, String>{};
  final counts = <String?, Map<String, int>>{};
  final invalidParents = <String?>{};
  var processed = 0;
  for (final entry in snapshot.values) {
    check();
    final parent = entry.file.parentId;
    if (renameValidationError(entry.name) != null) {
      invalidParents.add(parent);
    } else {
      final key = comparisonKey(entry.name);
      keys[entry.file.id] = key;
      final siblings = counts.putIfAbsent(parent, () => {});
      siblings[key] = (siblings[key] ?? 0) + 1;
    }
    if (++processed % 128 == 0) {
      await Future<void>.delayed(Duration.zero);
      check();
    }
  }
  final result = <String, SearchStatus>{};
  for (final entry in snapshot.values) {
    check();
    final ancestry = <({String id, String name})>[];
    SearchEntry? node = entry;
    var safe = true;
    while (node != null) {
      final parent = node.file.parentId;
      if (ancestry.length > 256 ||
          invalidParents.contains(parent) ||
          counts[parent]?[keys[node.file.id]] != 1) {
        safe = false;
        break;
      }
      ancestry.add((id: node.file.id, name: node.name));
      if (parent == null) break;
      node = snapshot[parent];
      if (node == null || !node.file.isDir) {
        safe = false;
        break;
      }
    }
    var status = SearchStatus.unknown;
    if (safe) {
      final availability = await inspectLocalAvailability(
          ancestry: ancestry.reversed.toList(),
          folders: roots,
          isDir: entry.file.isDir,
          cancelled: cancelled);
      check();
      status = switch (availability.displayLabel) {
        'Local' => SearchStatus.local,
        'Cloud only' => SearchStatus.cloudOnly,
        'Not covered' => SearchStatus.notCovered,
        'Syncing' => SearchStatus.syncing,
        'Conflict' => SearchStatus.conflict,
        'Error' => SearchStatus.error,
        _ => SearchStatus.unknown,
      };
    }
    result[entry.file.id] = status;
    if (++processed % 128 == 0) {
      await Future<void>.delayed(Duration.zero);
      check();
    }
  }
  return result;
}
