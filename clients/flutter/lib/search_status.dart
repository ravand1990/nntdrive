import 'account_search.dart';
import 'search_status_names.dart';
import 'search_status_errors.dart';
import 'local_availability.dart';
import 'sync_controller.dart';

// Only local_availability's consumed fields belong in this refresh snapshot.
// Do not enumerate report/progress/error keys or recursively copy diagnostics.
// Required lists still cost O(exclusions + conflicts + structured error paths)
// synchronously: every root must be frozen before the first indexing await.
SyncFolderConfig _freezeStatusFolder(
    SyncFolderConfig folder, void Function() check) {
  check();
  final errors = <Map<String, dynamic>>[];
  final sourceErrors = folder.lastReport?['item_errors'];
  if (sourceErrors is List) {
    for (final error in sourceErrors) {
      check();
      if (error is! Map) continue;
      final operation = error['operation'];
      if (operation is! String) continue;
      final code = error['code'];
      if (code is! String) continue;
      final sourcePaths = error['paths'];
      if (sourcePaths is! List) continue;
      final paths = <String>[];
      for (final path in sourcePaths) {
        check();
        if (path is String) paths.add(path);
      }
      errors.add({
        'operation': operation,
        'code': code,
        'paths': List<String>.unmodifiable(paths),
      });
    }
  }
  final progress = folder.progress;
  final path = progress?['path'];
  final complete = progress?['complete'];
  return SyncFolderConfig(
      id: folder.id,
      name: folder.name,
      localPath: folder.localPath,
      remoteRootId: folder.remoteRootId,
      excluded: List<String>.unmodifiable(folder.excluded),
      lastReport: {'item_errors': errors})
    ..conflictFiles = List<String>.unmodifiable(folder.conflictFiles)
    ..running = folder.running
    ..progress = progress == null
        ? null
        : {
            'path': path is String ? path : null,
            'complete': complete is bool ? complete : null,
          };
}

/// No HTTP, re-decryption, journal equality, paths or diagnostics in the result.
/// The complete authenticated index supplies sibling/ancestor evidence. Only
/// scalar statuses are later copied into immutable query-worker entries.
Future<Map<String, SearchStatus>> inspectSearchStatuses({
  required Map<String, SearchEntry> snapshot,
  required List<SyncFolderConfig> folders,
  Future<Set<String>> Function(Stream<List<SearchStatusName>>) groupNames =
      groupSearchStatusNames,
  Future<List<Set<String>>> Function(
          int, Stream<List<SearchStatusErrorPath>>) indexErrors =
      indexSearchStatusErrors,
  required bool Function() cancelled,
}) async {
  void check() {
    if (cancelled()) throw const SearchUnavailable();
  }

  check();
  if (snapshot.length > 100000) throw const SearchUnavailable();
  // Freeze controller evidence before the first await. Never retain mutable
  // progress/reports across inspections or send controller objects to workers.
  final roots = [for (final folder in folders) _freezeStatusFolder(folder, check)];
  Stream<List<SearchStatusErrorPath>> errorBatches() async* {
    var batch = <SearchStatusErrorPath>[];
    for (var i = 0; i < roots.length; i++) {
      check();
      final errors = roots[i].lastReport!['item_errors'] as List;
      for (final error in errors) {
        check();
        for (final path in error['paths'] as List<String>) {
          check();
          batch.add((root: i, path: path));
          if (batch.length == searchStatusErrorBatchSize) {
            yield batch;
            check();
            batch = <SearchStatusErrorPath>[];
          }
        }
      }
      // No per-entry report retention/rescanning after the index is built.
      roots[i].lastReport = null;
    }
    if (batch.isNotEmpty) yield batch;
    check();
  }

  final indexes = await indexErrors(roots.length, errorBatches());
  check();
  final failedPathsByFolder = <SyncFolderConfig, Set<String>>{
    for (var i = 0; i < roots.length; i++) roots[i]: indexes[i],
  };
  Stream<List<SearchStatusName>> nameBatches() async* {
    var batch = <SearchStatusName>[];
    for (final entry in snapshot.values) {
      check();
      batch.add(
          (id: entry.file.id, parent: entry.file.parentId, name: entry.name));
      if (batch.length == AccountSearch.decryptBatchSize) {
        yield batch;
        check();
        batch = <SearchStatusName>[];
      }
    }
    if (batch.isNotEmpty) yield batch;
  }

  final safeIds = await groupNames(nameBatches());
  check();
  var processed = 0;
  final result = <String, SearchStatus>{};
  for (final entry in snapshot.values) {
    check();
    final ancestry = <({String id, String name})>[];
    SearchEntry? node = entry;
    var safe = true;
    while (node != null) {
      final parent = node.file.parentId;
      if (ancestry.length > 256 || !safeIds.contains(node.file.id)) {
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
          failedPathsByFolder: failedPathsByFolder,
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
