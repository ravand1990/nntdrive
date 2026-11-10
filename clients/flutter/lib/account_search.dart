import 'dart:async';

import 'package:flutter/foundation.dart';

import 'api.dart';
import 'session_operations.dart';

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
/// Cooperative bounded work yields to Flutter between batches, including during
/// decryption. This is not a durable offline index or a content extractor.
class AccountSearch extends ChangeNotifier {
  AccountSearch({
    required this.handle,
    required this.operations,
    required this.list,
    required this.decrypt,
    required this.authorize,
  });
  final int handle;
  final SessionOperations operations;
  final Future<List<RemoteFile>> Function(String? parent) list;
  final String Function(RemoteFile file) decrypt;
  final void Function() authorize;
  Map<String, SearchEntry> _entries = {};
  final List<SearchFilter> _recent = [];
  final List<SearchFilter> _saved = [];
  List<SearchFilter> get recent => List.unmodifiable(_recent);
  List<SearchFilter> get saved => List.unmodifiable(_saved);
  int get count => _entries.length;
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
    _entries.clear();
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
    failed = false;
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
          for (final file in files) {
            _check(epoch);
            if (file.parentId != parent.id ||
                candidate.containsKey(file.id) ||
                candidate.length >= 100000 ||
                parent.depth > 256) {
              throw const SearchUnavailable();
            }
            final name = decrypt(
              file,
            ); // Authenticated native name opening only.
            candidate[file.id] = SearchEntry(file, name);
            if (file.isDir) queue.add((id: file.id, depth: parent.depth + 1));
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

  /// No query or filter ever reaches list(). Keep only a bounded ranked top 200
  /// and yield during large scans instead of sorting 100k matches on the UI.
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
        final snapshot = _entries;
        final text = filter.text.trim().toLowerCase();
        final terms =
            text.split(RegExp(r'\s+')).where((s) => s.isNotEmpty).toList();
        final extension = filter.extension.trim().toLowerCase().replaceFirst(
              RegExp(r'^\.'),
              '',
            );
        final best = <({SearchEntry entry, int rank})>[];
        final cap = limit.clamp(1, 200);
        final slice = Stopwatch()..start();
        for (final entry in snapshot.values) {
          if (query != _query) return <SearchEntry>[];
          _check(epoch);
          final f = entry.file;
          final name = entry.foldedName;
          final date = f.updatedAt;
          if ((filter.kind != SearchKind.file || !f.isDir) &&
              (filter.kind != SearchKind.folder || f.isDir) &&
              (!filter.favoritesOnly || f.favorite) &&
              (filter.minSize == null ||
                  (!f.isDir && f.size >= filter.minSize!)) &&
              (filter.maxSize == null ||
                  (!f.isDir && f.size <= filter.maxSize!)) &&
              (filter.modifiedAfter == null ||
                  (date != null && !date.isBefore(filter.modifiedAfter!))) &&
              (filter.modifiedBefore == null ||
                  (date != null && date.isBefore(filter.modifiedBefore!))) &&
              (extension.isEmpty ||
                  (!f.isDir && name.endsWith('.$extension'))) &&
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
          if (slice.elapsedMilliseconds >= 4) {
            await Future<void>.delayed(Duration.zero);
            _check(epoch);
            if (query != _query) return <SearchEntry>[];
            slice.reset();
          }
        }
        _check(epoch);
        _authorize();
        if (query != _query) return <SearchEntry>[];
        return best.map((e) => e.entry).toList();
      });
    } catch (_) {
      throw const SearchUnavailable();
    }
  }
}
