// Explicit local-only review of frozen indexed downloaded revisions (#84).
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'download_cache.dart';

class DuplicateLimits {
  const DuplicateLimits({
    this.maxEntries = 1000,
    this.maxBytes = 256 * 1024 * 1024,
    this.maxTime = const Duration(seconds: 2),
    this.maxGroups = 20,
    this.maxRows = 100,
  });
  final int maxEntries;

  /// All content reads count, including byte comparisons, not only hashing.
  final int maxBytes;
  final Duration maxTime;
  final int maxGroups;
  final int maxRows;
}

class CacheDuplicateReview {
  CacheDuplicateReview({
    required List<List<CachedDownload>> groups,
    required this.examined,
    required this.excluded,
    required this.bytesRead,
    required this.partial,
  }) : groups = List.unmodifiable(
         groups.map(List<CachedDownload>.unmodifiable),
       );
  final List<List<CachedDownload>> groups;
  final int examined;
  final int excluded;
  final int bytesRead;

  /// Bounds, unsafe/changed copies or omitted output mean incomplete coverage.
  final bool partial;
}

typedef CacheDuplicateRunner =
    Future<CacheDuplicateReview> Function(
      String root,
      List<CachedDownload> entries,
      DuplicateLimits limits,
    );

/// Separate top-level context: never capture a cache, controller or completer.
Future<CacheDuplicateReview> runCacheDuplicateReview(
  String root,
  List<CachedDownload> entries,
  DuplicateLimits limits,
) => Isolate.run(() => _review(root, entries, limits));

class _BudgetEnd implements Exception {}

class _Budget {
  _Budget(this.limits) : clock = Stopwatch()..start();
  final DuplicateLimits limits;
  final Stopwatch clock;
  int bytes = 0;
  void check() {
    if (clock.elapsed >= limits.maxTime) throw _BudgetEnd();
  }

  void read(int count) {
    check();
    if (count > limits.maxBytes - bytes) throw _BudgetEnd();
    bytes += count;
  }
}

// Checks each component without following links; canonical spellings are
// required. These pre/post checks are not atomic against hostile local swaps.
void _rootSafe(String root) {
  if (!p.isAbsolute(root) || p.normalize(root) != root) {
    throw StateError('Cache review unavailable');
  }
  var part = root;
  while (true) {
    if (FileSystemEntity.typeSync(part, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw StateError('Cache review unavailable');
    }
    final parent = p.dirname(part);
    if (parent == part) break;
    part = parent;
  }
  if (!p.equals(Directory(root).resolveSymbolicLinksSync(), root)) {
    throw StateError('Cache review unavailable');
  }
}

FileStat _copySafe(String root, CachedDownload entry) {
  _rootSafe(root);
  if (!RegExp(r'^[0-9a-f]{32}\.bin$').hasMatch(entry.fileName)) {
    throw StateError('Unsafe indexed copy');
  }
  final path = p.join(root, entry.fileName);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.equals(File(path).resolveSymbolicLinksSync(), path)) {
    throw StateError('Unsafe indexed copy');
  }
  final stat = File(path).statSync();
  if (stat.type != FileSystemEntityType.file || stat.size != entry.sizeBytes) {
    throw StateError('Changed indexed copy');
  }
  return stat;
}

bool _sameStat(FileStat a, FileStat b) =>
    a.size == b.size &&
    a.modified == b.modified &&
    a.changed == b.changed &&
    a.mode == b.mode;

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

String _hash(String path, int size, _Budget budget) {
  final output = _DigestSink();
  final sink = sha256.startChunkedConversion(output);
  final file = File(path).openSync(mode: FileMode.read);
  try {
    var left = size;
    while (left > 0) {
      final count = left < 65536 ? left : 65536;
      budget.read(count);
      final bytes = file.readSync(count);
      if (bytes.length != count) throw StateError('Changed indexed copy');
      sink.add(bytes);
      left -= count;
    }
    if (file.lengthSync() != size) throw StateError('Changed indexed copy');
    sink.close();
    return output.value.toString();
  } finally {
    file.closeSync();
  }
}

bool _equal(String a, String b, int size, _Budget budget) {
  final first = File(a).openSync(mode: FileMode.read);
  RandomAccessFile? second;
  try {
    second = File(b).openSync(mode: FileMode.read);
    var left = size;
    final x = Uint8List(65536);
    final y = Uint8List(65536);
    while (left > 0) {
      final count = left < x.length ? left : x.length;
      budget.read(count * 2);
      if (first.readIntoSync(x, 0, count) != count ||
          second.readIntoSync(y, 0, count) != count) {
        throw StateError('Changed indexed copy');
      }
      for (var i = 0; i < count; i++) {
        if (x[i] != y[i]) return false;
      }
      left -= count;
    }
    return first.lengthSync() == size && second.lengthSync() == size;
  } finally {
    second?.closeSync();
    first.closeSync();
  }
}

CacheDuplicateReview _review(
  String root,
  List<CachedDownload> entries,
  DuplicateLimits limits,
) {
  if (limits.maxEntries < 0 ||
      limits.maxEntries > downloadCacheMaxEntries ||
      limits.maxBytes < 0 ||
      limits.maxBytes > 256 * 1024 * 1024 ||
      limits.maxTime.isNegative ||
      limits.maxTime > const Duration(seconds: 2) ||
      limits.maxGroups < 0 ||
      limits.maxGroups > 20 ||
      limits.maxRows < 0 ||
      limits.maxRows > 100 ||
      entries.length > downloadCacheMaxEntries) {
    throw ArgumentError('Invalid cache review bounds');
  }
  _rootSafe(root);
  final budget = _Budget(limits);
  final stats = <CachedDownload, FileStat>{};
  final candidates = <String, List<CachedDownload>>{};
  final groups = <List<CachedDownload>>[];
  final rejected = <CachedDownload>{};
  var examined = 0;
  var partial = entries.length > limits.maxEntries;
  try {
    for (final entry in entries.take(limits.maxEntries)) {
      budget.check();
      examined++;
      try {
        final before = _copySafe(root, entry);
        final digest = _hash(p.join(root, entry.fileName), before.size, budget);
        if (!_sameStat(before, _copySafe(root, entry))) {
          throw StateError('Changed indexed copy');
        }
        stats[entry] = before;
        candidates.putIfAbsent('${before.size}:$digest', () => []).add(entry);
      } on _BudgetEnd {
        rethrow;
      } catch (_) {
        rejected.add(entry);
      }
    }
    // A digest only selects candidates; partition collisions by exact bytes.
    for (final bucket in candidates.values.where((b) => b.length > 1)) {
      final partitions = <List<CachedDownload>>[];
      for (final entry in bucket) {
        budget.check();
        try {
          if (!_sameStat(stats[entry]!, _copySafe(root, entry))) {
            throw StateError('Changed indexed copy');
          }
          List<CachedDownload>? match;
          for (final group in partitions) {
            final representative = group.first;
            if (!_sameStat(
              stats[representative]!,
              _copySafe(root, representative),
            )) {
              rejected.add(representative);
              continue;
            }
            final equal = _equal(
              p.join(root, representative.fileName),
              p.join(root, entry.fileName),
              entry.sizeBytes,
              budget,
            );
            if (!_sameStat(stats[entry]!, _copySafe(root, entry)) ||
                !_sameStat(
                  stats[representative]!,
                  _copySafe(root, representative),
                )) {
              throw StateError('Changed indexed copy');
            }
            if (equal) {
              match = group;
              break;
            }
          }
          if (match == null) {
            partitions.add([entry]);
          } else {
            match.add(entry);
          }
        } on _BudgetEnd {
          rethrow;
        } catch (_) {
          rejected.add(entry);
        }
      }
      groups.addAll(partitions.where((g) => g.length > 1));
    }
  } on _BudgetEnd {
    partial = true;
  }
  // Revalidate before returning bounded display evidence. Drop any group member
  // changed since hashing/comparison, never repair the index or touch pins.
  final output = <List<CachedDownload>>[];
  var rows = 0;
  for (final group in groups) {
    final safe = <CachedDownload>[];
    for (final entry in group) {
      try {
        budget.check();
        if (!_sameStat(stats[entry]!, _copySafe(root, entry))) {
          throw StateError('Changed indexed copy');
        }
        if (!rejected.contains(entry)) safe.add(entry);
      } on _BudgetEnd {
        partial = true;
      } catch (_) {
        rejected.add(entry);
      }
    }
    if (safe.length < 2) continue;
    if (output.length >= limits.maxGroups || limits.maxRows - rows < 2) {
      partial = true;
      continue;
    }
    final kept = safe.take(limits.maxRows - rows).toList();
    if (kept.length != safe.length) partial = true;
    output.add(kept);
    rows += kept.length;
  }
  _rootSafe(root);
  return CacheDuplicateReview(
    groups: output,
    examined: examined,
    excluded: rejected.length,
    bytesRead: budget.bytes,
    partial: partial || rejected.isNotEmpty,
  );
}
