import 'dart:async';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import 'account_search.dart';
import 'conflict_paths.dart';
import 'file_rename.dart';
import 'sync_controller.dart';

/// Frozen conflict path hints only; never filesystem acceptance or controller maps.
typedef SearchStatusConflictPath = ({int root, String path});
const searchStatusConflictBatchSize = 128;

typedef SearchStatusConflictWorker =
    Future<List<PreparedConflictPaths>> Function(int rootCount, SendPort ready);

// Keep the closure's lexical context primitive: no producer, cancellation
// callback, Session or lifecycle completer may be implicitly captured.
Future<List<PreparedConflictPaths>> runSearchStatusConflictWorker(
  int rootCount,
  SendPort ready,
) => Isolate.run(() => _indexSearchStatusConflicts(rootCount, ready));

Future<List<PreparedConflictPaths>> _indexSearchStatusConflicts(
  int rootCount,
  SendPort ready,
) async {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  final paths = List.generate(rootCount, (_) => <String>{});
  final candidates = List.generate(rootCount, (_) => <String, Set<String>>{});
  var failed = false;
  try {
    await for (final message in requests) {
      if (message == null) break;
      final (batch, reply) =
          message as (List<SearchStatusConflictPath>, SendPort);
      try {
        if (failed ||
            batch.isEmpty ||
            batch.length > searchStatusConflictBatchSize) {
          throw const SearchUnavailable();
        }
        for (final entry in batch) {
          if (entry.root < 0 || entry.root >= rootCount) {
            throw const SearchUnavailable();
          }
          if (!paths[entry.root].add(entry.path)) continue;
          final original = originalConflictPath(entry.path);
          if (original != null &&
              p.posix.dirname(entry.path) == p.posix.dirname(original) &&
              !entry.path
                  .split('/')
                  .any((part) => renameValidationError(part) != null)) {
            (candidates[entry.root][original] ??= <String>{}).add(entry.path);
          }
        }
        reply.send(true);
      } catch (_) {
        failed = true;
        reply.send(false);
      }
    }
    if (failed) throw const SearchUnavailable();
    // Both deduplication and final immutable index construction stay here.
    // Include every root, even those with no valid paths (empty != absent).
    return List<PreparedConflictPaths>.unmodifiable([
      for (var i = 0; i < rootCount; i++)
        PreparedConflictPaths(
          Set<String>.unmodifiable(paths[i]),
          Map<String, List<String>>.unmodifiable({
            for (final entry in candidates[i].entries)
              entry.key: List<String>.unmodifiable(entry.value),
          }),
        ),
    ]);
  } finally {
    requests.close();
  }
}

/// One refresh owns one worker, including on producer failure/cancellation.
/// Sequential acknowledgements bound in-flight input; no accumulated sets are
/// sent back and forth. Only the final immutable indexes leave the worker.
Future<List<PreparedConflictPaths>> indexSearchStatusConflicts(
  int rootCount,
  Stream<List<SearchStatusConflictPath>> batches, {
  SearchStatusConflictWorker worker = runSearchStatusConflictWorker,
}) async {
  if (rootCount < 0) throw const SearchUnavailable();
  final ready = ReceivePort();
  final running = worker(rootCount, ready.sendPort);
  late final SendPort requests;
  try {
    requests = await Future.any([
      ready.first.then((value) => value as SendPort),
      running.then<SendPort>((_) => throw const SearchUnavailable()),
    ]);
  } finally {
    ready.close();
  }
  List<PreparedConflictPaths>? result;
  try {
    await for (final batch in batches) {
      final reply = ReceivePort();
      try {
        requests.send((batch, reply.sendPort));
        if (await reply.first != true) throw const SearchUnavailable();
      } finally {
        reply.close();
      }
    }
  } catch (_) {
    throw const SearchUnavailable();
  } finally {
    requests.send(null);
    // Await even after the producer fails: session drain must not revoke keys
    // or release the owned build while a worker is still finalizing its indexes.
    result = await running;
  }
  return result;
}
