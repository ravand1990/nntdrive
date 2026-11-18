import 'dart:async';
import 'dart:isolate';

import 'account_search.dart';
import 'conflict_paths.dart';
import 'local_availability.dart';
import 'search_status_ancestry.dart';
import 'sync_controller.dart';

const searchStatusFilesystemBatchSize = 128;
typedef SearchStatusRoot = ({
  String id,
  String name,
  String localPath,
  String remoteRootId,
  List<String> excluded,
  bool running,
  String? progressPath,
  bool? progressComplete,
  Set<String> errors,
  PreparedConflictPaths conflicts,
});
typedef SearchStatusValue = ({String id, SearchStatus status});
typedef SearchStatusFilesystemInspect =
    Future<List<SearchStatusValue>> Function(List<SearchStatusAncestry>);
typedef SearchStatusFilesystemProducer =
    Future<void> Function(SearchStatusFilesystemInspect inspect);
typedef SearchStatusFilesystemWorker =
    Future<void> Function(List<SearchStatusRoot> roots, SendPort ready);

// Only frozen scalar evidence and a port are captured, never a controller,
// native library, producer callback, cancellation closure or session completer.
Future<void> runSearchStatusFilesystemWorker(
  List<SearchStatusRoot> roots,
  SendPort ready,
) => Isolate.run(() => _filesystemWorker(roots, ready));

Future<void> _filesystemWorker(
  List<SearchStatusRoot> roots,
  SendPort ready,
) async {
  final folders = <SyncFolderConfig>[];
  final errors = <SyncFolderConfig, Set<String>>{};
  final conflicts = <SyncFolderConfig, PreparedConflictPaths>{};
  for (final root in roots) {
    final folder = SyncFolderConfig(
      id: root.id,
      name: root.name,
      localPath: root.localPath,
      remoteRootId: root.remoteRootId,
      excluded: root.excluded,
    )..running = root.running;
    folder.progress = {
      'path': root.progressPath,
      'complete': root.progressComplete,
    };
    folders.add(folder);
    errors[folder] = root.errors;
    conflicts[folder] = root.conflicts;
  }
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  var failed = false;
  try {
    await for (final message in requests) {
      if (message == null) break;
      final (batch, reply) = message as (List<SearchStatusAncestry>, SendPort);
      try {
        if (failed ||
            batch.isEmpty ||
            batch.length > searchStatusFilesystemBatchSize) {
          throw const SearchUnavailable();
        }
        final result = <SearchStatusValue>[];
        for (final entry in batch) {
          var status = SearchStatus.unknown;
          final ancestry = entry.ancestry;
          if (ancestry != null) {
            final availability = await inspectLocalAvailability(
              ancestry: ancestry,
              folders: folders,
              failedPathsByFolder: errors,
              conflictPathsByFolder: conflicts,
              isDir: entry.isDir,
            );
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
          // Never return LocalAvailability: it contains paths and explanations.
          result.add((id: entry.id, status: status));
        }
        reply.send(result);
      } catch (_) {
        failed = true;
        reply.send(false);
      }
    }
    if (failed) throw const SearchUnavailable();
  } finally {
    requests.close();
  }
}

/// One refresh-owned worker receives roots once, then sequential <=128-entry
/// ancestry batches. Filesystem acceptance is always fresh, not cached. The
/// caller checks cancellation before/after requests; an admitted batch finishes
/// before shutdown/drain returns, including after producer failure.
Future<void> inspectSearchStatusFilesystem(
  List<SearchStatusRoot> roots,
  SearchStatusFilesystemProducer produce, {
  SearchStatusFilesystemWorker worker = runSearchStatusFilesystemWorker,
}) async {
  final ready = ReceivePort();
  final running = worker(roots, ready.sendPort);
  late final SendPort requests;
  try {
    requests = await Future.any([
      ready.first.then((value) => value as SendPort),
      running.then<SendPort>((_) => throw const SearchUnavailable()),
    ]);
  } finally {
    ready.close();
  }
  try {
    await produce((batch) async {
      final reply = ReceivePort();
      try {
        requests.send((batch, reply.sendPort));
        final result = await reply.first;
        if (result == false) throw const SearchUnavailable();
        return result as List<SearchStatusValue>;
      } finally {
        reply.close();
      }
    });
  } catch (_) {
    throw const SearchUnavailable();
  } finally {
    requests.send(null);
    await running;
  }
}
