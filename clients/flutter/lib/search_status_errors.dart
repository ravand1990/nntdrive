import 'dart:async';
import 'dart:isolate';

import 'account_search.dart';

/// Validated frozen string paths only; never controller/report/diagnostic maps.
typedef SearchStatusErrorPath = ({int root, String path});
const searchStatusErrorBatchSize = 128;

typedef SearchStatusErrorWorker =
    Future<List<Set<String>>> Function(int rootCount, SendPort ready);

// Keep the closure's lexical context primitive: no producer, cancellation
// callback, Session or lifecycle completer may be implicitly captured.
Future<List<Set<String>>> runSearchStatusErrorWorker(
  int rootCount,
  SendPort ready,
) => Isolate.run(() => _indexSearchStatusErrors(rootCount, ready));

Future<List<Set<String>>> _indexSearchStatusErrors(
  int rootCount,
  SendPort ready,
) async {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  final paths = List.generate(rootCount, (_) => <String>{});
  var failed = false;
  try {
    await for (final message in requests) {
      if (message == null) break;
      final (batch, reply) = message as (List<SearchStatusErrorPath>, SendPort);
      try {
        if (failed ||
            batch.isEmpty ||
            batch.length > searchStatusErrorBatchSize) {
          throw const SearchUnavailable();
        }
        for (final entry in batch) {
          if (entry.root < 0 || entry.root >= rootCount) {
            throw const SearchUnavailable();
          }
          paths[entry.root].add(entry.path);
        }
        reply.send(true);
      } catch (_) {
        failed = true;
        reply.send(false);
      }
    }
    if (failed) throw const SearchUnavailable();
    // Both deduplication and final immutable-set construction stay here.
    // Include every root, even those with no valid paths (empty != absent).
    return List<Set<String>>.unmodifiable(
      paths.map((values) => Set<String>.unmodifiable(values)),
    );
  } finally {
    requests.close();
  }
}

/// One refresh owns one worker, including on producer failure/cancellation.
/// Sequential acknowledgements bound in-flight input; no accumulated sets are
/// sent back and forth. Only the final immutable indexes leave the worker.
Future<List<Set<String>>> indexSearchStatusErrors(
  int rootCount,
  Stream<List<SearchStatusErrorPath>> batches, {
  SearchStatusErrorWorker worker = runSearchStatusErrorWorker,
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
  List<Set<String>>? result;
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
    // or release the owned build while a worker is still finalizing its sets.
    result = await running;
  }
  return result;
}
