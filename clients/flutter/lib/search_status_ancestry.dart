import 'dart:async';
import 'dart:isolate';

import 'account_search.dart';

const searchStatusAncestryBatchSize = 128;
typedef SearchStatusNode = ({
  String key,
  String id,
  String? parent,
  String name,
  bool isDir,
});
typedef SearchStatusAncestry = ({
  String id,
  bool isDir,
  List<({String id, String name})>? ancestry,
});
typedef SearchStatusAncestryWorker =
    Future<void> Function(Set<String> safeIds, SendPort ready);

// Top-level primitive-only context: no controller, native handle or producer.
Future<void> runSearchStatusAncestryWorker(
  Set<String> safeIds,
  SendPort ready,
) => Isolate.run(() => _statusAncestryWorker(safeIds, ready));

Future<void> _statusAncestryWorker(Set<String> safeIds, SendPort ready) async {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  final nodes = <String, SearchStatusNode>{};
  var reading = false;
  var failed = false;
  try {
    await for (final message in requests) {
      if (message == null) break;
      final (input, reply) = message as (Object, SendPort);
      try {
        if (failed) throw const SearchUnavailable();
        if (input is List<SearchStatusNode>) {
          if (reading ||
              input.isEmpty ||
              input.length > searchStatusAncestryBatchSize ||
              nodes.length + input.length > 100000) {
            throw const SearchUnavailable();
          }
          for (final node in input) {
            if (nodes.containsKey(node.key)) throw const SearchUnavailable();
            nodes[node.key] = node;
          }
          reply.send(true);
        } else {
          reading = true;
          final keys = input as List<String>;
          if (keys.isEmpty || keys.length > searchStatusAncestryBatchSize) {
            throw const SearchUnavailable();
          }
          final result = <SearchStatusAncestry>[];
          for (final key in keys) {
            final entry = nodes[key];
            if (entry == null) throw const SearchUnavailable();
            SearchStatusNode? node = entry;
            final ancestry = <({String id, String name})>[];
            var safe = true;
            while (node != null) {
              final parent = node.parent;
              // Exactly the old bound: 257 nodes may reach a null parent;
              // a 258th node (including cycles) fails closed.
              if (ancestry.length > 256 || !safeIds.contains(node.id)) {
                safe = false;
                break;
              }
              ancestry.add((id: node.id, name: node.name));
              if (parent == null) break;
              node = nodes[parent];
              if (node == null || !node.isDir) {
                safe = false;
                break;
              }
            }
            result.add((
              id: entry.id,
              isDir: entry.isDir,
              ancestry: safe ? ancestry.reversed.toList() : null,
            ));
          }
          // Only one requested batch leaves the worker, never all ancestries.
          reply.send(result);
        }
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

/// One refresh-owned scalar snapshot, then sequential bounded requested outputs.
/// Consumer IO is awaited before requesting another batch. Always finish/drain,
/// including producer/consumer failure and cancellation thrown by either side.
Future<void> inspectSearchStatusAncestries(
  Stream<List<SearchStatusNode>> nodes,
  Set<String> safeIds,
  Stream<List<String>> requests,
  Future<void> Function(List<SearchStatusAncestry>) consume, {
  SearchStatusAncestryWorker worker = runSearchStatusAncestryWorker,
}) async {
  final ready = ReceivePort();
  final running = worker(safeIds, ready.sendPort);
  late final SendPort port;
  try {
    port = await Future.any([
      ready.first.then((value) => value as SendPort),
      running.then<SendPort>((_) => throw const SearchUnavailable()),
    ]);
  } finally {
    ready.close();
  }
  Future<Object?> send(Object batch) async {
    final reply = ReceivePort();
    try {
      port.send((batch, reply.sendPort));
      final value = await reply.first;
      if (value == false) throw const SearchUnavailable();
      return value;
    } finally {
      reply.close();
    }
  }

  try {
    await for (final batch in nodes) {
      await send(batch);
    }
    await for (final batch in requests) {
      await consume(await send(batch) as List<SearchStatusAncestry>);
    }
  } catch (_) {
    throw const SearchUnavailable();
  } finally {
    port.send(null);
    await running;
  }
}
