import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'session_operations.dart';

/// Captures only sendable RAM data, never the controller or session completers.
Future<List<String>> runSearchQuery(
  Map<String, SearchEntry> snapshot,
  SearchFilter filter,
  int limit,
) =>
    Isolate.run(() => _scanSearch(snapshot, filter, limit));

/// Only the current bounded opaque batch and scalar traversal context cross the
/// boundary. Global membership and the growing candidate stay with the caller.
typedef SearchTraversalBatch = ({List<String> ids, List<String> directoryIds});

Future<SearchTraversalBatch> runSearchTraversalBatch(
  List<RemoteFile> files,
  String? parent,
  int depth,
  int remainingCapacity,
) =>
    Isolate.run(() =>
        _validateSearchTraversal(files, parent, depth, remainingCapacity));

SearchTraversalBatch _validateSearchTraversal(
  List<RemoteFile> files,
  String? parent,
  int depth,
  int remainingCapacity,
) {
  if (files.isEmpty ||
      files.length > AccountSearch.decryptBatchSize ||
      files.length > remainingCapacity ||
      depth > 256) {
    throw const SearchUnavailable();
  }
  final ids = <String>{};
  final directories = <String>[];
  for (final file in files) {
    if (file.parentId != parent || !ids.add(file.id)) {
      throw const SearchUnavailable();
    }
    if (file.isDir) directories.add(file.id);
  }
  return (ids: ids.toList(), directoryIds: directories);
}

/// Bounded cold folding/entry-map construction. Captures only sendable RAM,
/// never an AccountSearch, native bridge or session lifecycle object.
Future<Map<String, SearchEntry>> runSearchEntryBatch(
  List<RemoteFile> files,
  List<String?> names,
) =>
    Isolate.run(() => _assembleSearchEntries(files, names));

Map<String, SearchEntry> _assembleSearchEntries(
  List<RemoteFile> files,
  List<String?> names,
) {
  if (files.isEmpty ||
      files.length > AccountSearch.decryptBatchSize ||
      files.length != names.length) {
    throw const SearchUnavailable();
  }
  final entries = <String, SearchEntry>{};
  for (var i = 0; i < files.length; i++) {
    final name = names[i];
    final file = files[i];
    if (name == null || entries.containsKey(file.id)) {
      throw const SearchUnavailable();
    }
    entries[file.id] = SearchEntry(file, name);
  }
  return entries;
}

/// Deliberately diagnostic-free: upstream errors may contain names or tokens.
class SearchUnavailable implements Exception {
  const SearchUnavailable();
  @override
  String toString() => 'Search unavailable. Unlock or rebuild the index.';
}

enum SearchKind { any, file, folder }

@immutable
class SearchFilter {
  const SearchFilter({
    this.text = '',
    this.kind = SearchKind.any,
    this.extension = '',
    this.minSize,
    this.maxSize,
    this.modifiedAfter,
    this.modifiedBefore,
    this.favoritesOnly = false,
  });
  final String text;
  final SearchKind kind;
  final String extension;
  final int? minSize;
  final int? maxSize;
  final DateTime? modifiedAfter;
  final DateTime? modifiedBefore;
  final bool favoritesOnly;
}

class SearchEntry {
  SearchEntry(this.file, this.name) : foldedName = name.toLowerCase();
  final RemoteFile file;
  final String name;
  final String foldedName;
  // Do not add a plaintext toString/JSON serializer.
}

/// One unlocked account/session only. No preferences, files, telemetry or query
/// HTTP endpoint. A successful build is an atomic, rebuildable RAM snapshot.
/// Production decryption uses sequential bounded worker batches; injected sync
/// fixtures remain supported. Query scans/filtering/top-k run off-isolate;
/// bounded cold entry construction/folding also run on worker isolates.
/// Production Session listings bound response bytes and decode/build RemoteFile
/// models on workers. Bounded traversal validation/discovery also uses workers;
/// global membership, reuse, queue updates and final merging stay caller-side.
/// This is not a durable offline index or a content extractor.
class AccountSearch extends ChangeNotifier {
  AccountSearch({
    required this.handle,
    required this.operations,
    required this.list,
    required this.decrypt,
    this.decryptBatch,
    this.queryWorker = runSearchQuery,
    this.entryWorker = runSearchEntryBatch,
    this.traversalWorker = runSearchTraversalBatch,
    required this.authorize,
  });
  static const decryptBatchSize = 128;
  final int handle;
  final SessionOperations operations;
  final Future<List<RemoteFile>> Function(String? parent) list;
  final String Function(RemoteFile file) decrypt;

  /// Ordered, all-or-error names. Never invoked concurrently by a build.
  final Future<List<String>> Function(List<RemoteFile> files)? decryptBatch;

  /// Ordered bounded construction; awaited within the owned build workflow.
  /// Test seam; production always uses the top-level isolate helper.
  final Future<Map<String, SearchEntry>> Function(
      List<RemoteFile>, List<String?>) entryWorker;
  final void Function() authorize;

  /// Sequential bounded validation/discovery, before any reuse or decryption.
  /// Test seam; production always uses the top-level isolate helper.
  final Future<SearchTraversalBatch> Function(
      List<RemoteFile>, String?, int, int) traversalWorker;

  /// Test seam; production always uses the top-level isolate boundary.
  final Future<List<String>> Function(
      Map<String, SearchEntry>, SearchFilter, int) queryWorker;
  Future<void> _queryTail = Future<void>.value();
  Map<String, SearchEntry> _entries = {};
  final List<SearchFilter> _recent = [];
  final List<SearchFilter> _saved = [];
  List<SearchFilter> get recent => List.unmodifiable(_recent);
  List<SearchFilter> get saved => List.unmodifiable(_saved);
  int get count => _entries.length;

  /// Changes only when a complete snapshot is successfully published.
  int get snapshotRevision => _snapshotRevision;
  int _snapshotRevision = 0;
  bool ready = false;
  bool building = false;
  bool failed = false;
  bool _closed = false;
  bool get closed => _closed;
  int _epoch = 0;
  int _query = 0;
  Future<void>? _build;

  void _check(int epoch) {
    if (_closed || epoch != _epoch) throw const SearchUnavailable();
  }

  void _authorize() {
    try {
      authorize();
    } catch (_) {
      close();
      throw const SearchUnavailable();
    }
  }

  /// Stop admission immediately, before the session drains and revokes keys.
  void close() {
    if (_closed) return;
    _closed = true;
    _epoch++;
    _query++;
    _entries = {}; // In-flight snapshots remain immutable until worker drain.
    _recent.clear();
    _saved.clear();
    ready = false;
    building = false;
    notifyListeners();
  }

  @override
  void dispose() {
    close();
    super.dispose();
  }

  Future<void> rebuild() {
    if (_closed) return Future.error(const SearchUnavailable());
    return _build ??= _rebuild().whenComplete(() => _build = null);
  }

  Future<void> _rebuild() async {
    final epoch = _epoch;
    building = true;
    notifyListeners();
    try {
      await operations.run(handle, () async {
        _check(epoch);
        _authorize(); // Locked handles fail before any HTTP request.
        final candidate = <String, SearchEntry>{};
        final queue = <({String? id, int depth})>[(id: null, depth: 0)];
        final slice = Stopwatch()..start();
        for (var cursor = 0; cursor < queue.length; cursor++) {
          final parent = queue[cursor];
          final files = await list(parent.id);
          _check(epoch); // Never decrypt a late response after close.
          for (var offset = 0;
              offset < files.length;
              offset += decryptBatchSize) {
            _check(epoch);
            final end = (offset + decryptBatchSize).clamp(0, files.length);
            final batch = files.sublist(offset, end);
            final traversal = await traversalWorker(
                batch, parent.id, parent.depth, 100000 - candidate.length);
            _check(epoch); // Discard late validation before reuse/decryption.
            // Global membership stays local: never resend the growing snapshot.
            for (final id in traversal.ids) {
              if (candidate.containsKey(id)) {
                throw const SearchUnavailable();
              }
            }
            // Reuse only names authenticated in this session's last complete
            // snapshot, under the exact same node ID and ciphertext envelope.
            // Metadata/membership still come from the fresh complete traversal.
            final names = List<String?>.filled(batch.length, null);
            final pending = <RemoteFile>[];
            final positions = <int>[];
            for (var i = 0; i < batch.length; i++) {
              final file = batch[i];
              final prior = _entries[file.id];
              if (prior != null && prior.file.nameEnc == file.nameEnc) {
                names[i] = prior.name;
              } else {
                pending.add(file);
                positions.add(i);
              }
            }
            // Await INSIDE operations.run: close/drain must retain the handle
            // until the worker has finished, even if publication is cancelled.
            if (pending.isNotEmpty) {
              final openBatch = decryptBatch;
              final opened = openBatch == null
                  ? pending.map(decrypt).toList()
                  : await openBatch(List.unmodifiable(pending));
              _check(epoch); // Discard every late worker result after close.
              if (opened.length != pending.length) {
                throw const SearchUnavailable();
              }
              for (var i = 0; i < opened.length; i++) {
                names[positions[i]] = opened[i];
              }
            }
            // Sequential bounded worker, including all-cached rebuild batches.
            // Do not copy the whole accumulated candidate into each worker.
            final entries = await entryWorker(batch, names);
            _check(
                epoch); // Close discards results, but drain awaits the worker.
            candidate.addAll(entries);
            for (final id in traversal.directoryIds) {
              queue.add((id: id, depth: parent.depth + 1));
            }
            if (slice.elapsedMilliseconds >= 4) {
              await Future<void>.delayed(Duration.zero);
              _check(epoch);
              slice.reset();
            }
          }
        }
        _check(epoch);
        _authorize();
        _query++; // Invalidate scans over the previous snapshot.
        _entries = candidate;
        _snapshotRevision++;
        failed = false;
        ready = true;
      });
    } catch (_) {
      if (!_closed) failed = true;
      throw const SearchUnavailable();
    } finally {
      if (!_closed) {
        building = false;
        notifyListeners();
      }
    }
  }

  List<SearchEntry> ancestors(SearchEntry entry) {
    _check(_epoch);
    final result = <SearchEntry>[];
    var parent = entry.file.parentId;
    while (parent != null) {
      final node = _entries[parent];
      if (node == null || result.length > 256) throw const SearchUnavailable();
      result.add(node);
      parent = node.file.parentId;
    }
    return result.reversed.toList();
  }

  String folderPath(SearchEntry entry) =>
      '/${ancestors(entry).map((e) => e.name).join('/')}';

  void remember(SearchFilter filter, {bool save = false}) {
    if (_closed) return;
    final target = save ? _saved : _recent;
    target.removeWhere(
      (f) =>
          f.text == filter.text &&
          f.kind == filter.kind &&
          f.extension == filter.extension &&
          f.minSize == filter.minSize &&
          f.maxSize == filter.maxSize &&
          f.modifiedAfter == filter.modifiedAfter &&
          f.modifiedBefore == filter.modifiedBefore &&
          f.favoritesOnly == filter.favoritesOnly,
    );
    target.insert(0, filter);
    if (target.length > 10) target.removeLast();
    notifyListeners();
  }

  /// No query/filter reaches list(). At most one query worker is in flight.
  /// Superseded queued queries never dispatch; running workers finish and drain.
  Future<List<SearchEntry>> search(
    SearchFilter filter, {
    int limit = 200,
  }) async {
    final epoch = _epoch;
    final query = ++_query;
    try {
      return await operations.run(handle, () async {
        _check(epoch);
        _authorize();
        if (!ready) return <SearchEntry>[];
        // Do not retain a snapshot for each queued keystroke.
        final previous = _queryTail;
        final done = Completer<void>();
        _queryTail = done.future;
        try {
          await previous;
          _check(epoch);
          if (query != _query) return <SearchEntry>[];
          final snapshot = _entries;
          final ids = await queryWorker(snapshot, filter, limit.clamp(1, 200));
          _check(epoch);
          _authorize();
          if (query != _query || !identical(snapshot, _entries)) {
            return <SearchEntry>[];
          }
          return ids.map((id) => snapshot[id]!).toList();
        } finally {
          done.complete();
        }
      });
    } catch (_) {
      throw const SearchUnavailable();
    }
  }
}

/// Pure synchronous scan: only called inside the production worker isolate.
List<String> _scanSearch(
    Map<String, SearchEntry> snapshot, SearchFilter filter, int limit) {
  final text = filter.text.trim().toLowerCase();
  final terms = text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
  final extension = filter.extension.trim().toLowerCase().replaceFirst(
        RegExp(r'^\.'),
        '',
      );
  final best = <({SearchEntry entry, int rank})>[];
  final cap = limit.clamp(1, 200);
  for (final entry in snapshot.values) {
    final f = entry.file;
    final name = entry.foldedName;
    final date = f.updatedAt;
    if ((filter.kind != SearchKind.file || !f.isDir) &&
        (filter.kind != SearchKind.folder || f.isDir) &&
        (!filter.favoritesOnly || f.favorite) &&
        (filter.minSize == null || (!f.isDir && f.size >= filter.minSize!)) &&
        (filter.maxSize == null || (!f.isDir && f.size <= filter.maxSize!)) &&
        (filter.modifiedAfter == null ||
            (date != null && !date.isBefore(filter.modifiedAfter!))) &&
        (filter.modifiedBefore == null ||
            (date != null && date.isBefore(filter.modifiedBefore!))) &&
        (extension.isEmpty || (!f.isDir && name.endsWith('.$extension'))) &&
        terms.every(name.contains)) {
      final rank = name == text
          ? 0
          : name.startsWith(text)
              ? 1
              : terms.any((term) => name.contains(' $term'))
                  ? 2
                  : 3;
      var low = 0;
      var high = best.length;
      while (low < high) {
        final mid = (low + high) >> 1;
        final other = best[mid];
        final order = rank != other.rank
            ? rank.compareTo(other.rank)
            : name != other.entry.foldedName
                ? name.compareTo(other.entry.foldedName)
                : f.id.compareTo(other.entry.file.id);
        if (order < 0) {
          high = mid;
        } else {
          low = mid + 1;
        }
      }
      if (low < cap) {
        best.insert(low, (entry: entry, rank: rank));
        if (best.length > cap) best.removeLast();
      }
    }
  }
  return best.map((e) => e.entry.file.id).toList();
}
