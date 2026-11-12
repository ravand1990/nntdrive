import 'dart:async';
import 'dart:isolate';

import 'account_search.dart';
import 'file_rename.dart';
import 'native.dart';

/// Only scalar RAM records cross the boundary, never a native bridge, Session,
/// controller, cancellation callback or decrypted-entry object.
typedef SearchStatusName = ({String id, String? parent, String name});

Future<Set<String>> _runSearchStatusNames(SendPort ready) =>
    Isolate.run(() => _groupSearchStatusNames(ready));

Future<Set<String>> _groupSearchStatusNames(SendPort ready) async {
  final requests = ReceivePort();
  ready.send(requests.sendPort);
  final keys = <String, ({String? parent, String? key})>{};
  final counts = <String?, Map<String, int>>{};
  final invalidParents = <String?>{};
  var failed = false;
  try {
    await for (final message in requests) {
      if (message == null) break;
      final (batch, reply) = message as (List<SearchStatusName>, SendPort);
      try {
        if (failed ||
            batch.isEmpty ||
            batch.length > AccountSearch.decryptBatchSize ||
            keys.length + batch.length > 100000) {
          throw const SearchUnavailable();
        }
        for (final entry in batch) {
          if (keys.containsKey(entry.id)) throw const SearchUnavailable();
          String? key;
          if (renameValidationError(entry.name) != null) {
            invalidParents.add(entry.parent);
          } else {
            key = NativeBridge.instance.nameCollisionKey(entry.name);
            final siblings = counts.putIfAbsent(entry.parent, () => {});
            siblings[key] = (siblings[key] ?? 0) + 1;
          }
          keys[entry.id] = (parent: entry.parent, key: key);
        }
        reply.send(true);
      } catch (_) {
        failed = true;
        reply.send(false);
      }
    }
    if (failed) throw const SearchUnavailable();
    // Finalize only after the complete snapshot: later batches may invalidate
    // earlier siblings (including their descendants through ancestry checks).
    return {
      for (final entry in keys.entries)
        if (!invalidParents.contains(entry.value.parent) &&
            entry.value.key != null &&
            counts[entry.value.parent]?[entry.value.key] == 1)
          entry.key
    };
  } finally {
    requests.close();
  }
}

/// One refresh-owned worker retains grouping state between bounded sequential
/// batches. No growing candidate/count map is recopied for each dispatch. The
/// final safe-ID set is returned only after all siblings have been considered.
/// Always finish/drain on stream cancellation/error; never abandon a worker.
Future<Set<String>> groupSearchStatusNames(
    Stream<List<SearchStatusName>> batches) async {
  final ready = ReceivePort();
  final worker = _runSearchStatusNames(ready.sendPort);
  late final SendPort requests;
  try {
    requests = await Future.any([
      ready.first.then((value) => value as SendPort),
      worker.then<SendPort>((_) => throw const SearchUnavailable()),
    ]);
  } finally {
    ready.close();
  }
  Set<String>? result;
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
  } finally {
    requests.send(null);
    // Includes errors/cancellation in the producer. Session drain cannot finish
    // until this worker releases its private grouping/native resources.
    result = await worker;
  }
  return result;
}
