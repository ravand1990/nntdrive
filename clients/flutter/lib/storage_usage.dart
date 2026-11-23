import 'dart:isolate';

import 'account_search.dart';

/// RAM-only logical live-file accounting, not physical/quota/history usage.
class StorageBucket {
  const StorageBucket(this.label, this.bytes, this.files);
  final String label;
  final int bytes;
  final int files;
}

class StorageFile {
  const StorageFile(this.path, this.bytes);
  final String path;
  final int bytes;
}

/// Namespace modification time, not last access or verified content age.
class StorageDatedFile extends StorageFile {
  const StorageDatedFile(super.path, super.bytes, this.updatedAt);
  final DateTime updatedAt;
}

const oldestLargeMinimumBytes = 10 * 1024 * 1024;

class StorageUsage {
  StorageUsage(
    this.bytes,
    this.files,
    List<StorageBucket> folders,
    List<StorageBucket> types,
    List<StorageFile> largest,
    List<StorageDatedFile> oldestLarge,
    this.unknownLargeDates,
  ) : folders = List.unmodifiable(folders),
      types = List.unmodifiable(types),
      largest = List.unmodifiable(largest),
      oldestLarge = List.unmodifiable(oldestLarge);
  final int bytes;
  final int files;
  final List<StorageBucket> folders;
  final List<StorageBucket> types;
  final List<StorageFile> largest;
  final List<StorageDatedFile> oldestLarge;
  final int unknownLargeDates;
}

/// Only immutable/sendable entries cross this top-level boundary. No Session,
/// bridge, HTTP client or lifecycle completer is captured. Full input copying,
/// spawn cost and the search build's caller-side work remain independent costs.
Future<StorageUsage> runStorageUsage(Map<String, SearchEntry> snapshot) =>
    Isolate.run(() => _aggregate(snapshot));

StorageUsage _aggregate(Map<String, SearchEntry> snapshot) {
  if (snapshot.length > 100000) throw const SearchUnavailable();
  final roots = <String, String>{};
  String top(String id) {
    final trail = <String>[];
    final seen = <String>{};
    var current = id;
    while (!roots.containsKey(current)) {
      if (!seen.add(current) || trail.length > 256) {
        throw const SearchUnavailable();
      }
      final entry = snapshot[current];
      if (entry == null || entry.file.id != current) {
        throw const SearchUnavailable();
      }
      trail.add(current);
      final parent = entry.file.parentId;
      if (parent == null) {
        roots[current] = current;
        break;
      }
      if (snapshot[parent]?.file.isDir != true) {
        throw const SearchUnavailable();
      }
      current = parent;
    }
    final root = roots[current]!;
    for (final node in trail) {
      roots[node] = root;
    }
    return root;
  }

  final folders = <String?, ({int bytes, int files})>{};
  final types = <String, ({int bytes, int files})>{};
  final largest = <SearchEntry>[];
  final oldestLarge = <SearchEntry>[];
  var unknownLargeDates = 0;
  var bytes = 0;
  var files = 0;
  int compareFiles(SearchEntry a, SearchEntry b) {
    final size = b.file.size.compareTo(a.file.size);
    return size != 0 ? size : a.file.id.compareTo(b.file.id);
  }

  for (final item in snapshot.entries) {
    final entry = item.value;
    final root = top(item.key);
    if (entry.file.isDir) {
      if (entry.file.parentId == null) {
        folders.putIfAbsent(item.key, () => (bytes: 0, files: 0));
      }
      continue;
    }
    final size = entry.file.size;
    if (size < 0 || bytes > 0x7fffffffffffffff - size) {
      throw const SearchUnavailable();
    }
    bytes += size;
    files++;
    final String? folder = entry.file.parentId == null ? null : root;
    final oldFolder = folders[folder] ?? (bytes: 0, files: 0);
    folders[folder] = (
      bytes: oldFolder.bytes + size,
      files: oldFolder.files + 1,
    );
    final dot = entry.name.lastIndexOf('.');
    final type = dot > 0 && dot < entry.name.length - 1
        ? entry.name.substring(dot).toLowerCase()
        : 'No extension';
    final oldType = types[type] ?? (bytes: 0, files: 0);
    types[type] = (bytes: oldType.bytes + size, files: oldType.files + 1);
    // Keep at most 20 winners, rather than sorting/retaining all file rows.
    final position = largest.indexWhere(
      (other) => compareFiles(entry, other) < 0,
    );
    if (position >= 0) {
      largest.insert(position, entry);
    } else if (largest.length < 20) {
      largest.add(entry);
    }
    if (largest.length > 20) largest.removeLast();
    if (size >= oldestLargeMinimumBytes) {
      final date = entry.file.updatedAt;
      if (date == null) {
        unknownLargeDates++;
      } else {
        final position = oldestLarge.indexWhere((other) {
          final time = date.compareTo(other.file.updatedAt!);
          return (time != 0 ? time : compareFiles(entry, other)) < 0;
        });
        if (position >= 0) {
          oldestLarge.insert(position, entry);
        } else if (oldestLarge.length < 20) {
          oldestLarge.add(entry);
        }
        if (oldestLarge.length > 20) oldestLarge.removeLast();
      }
    }
  }

  List<StorageBucket> bounded(List<StorageBucket> buckets) {
    buckets.sort((a, b) {
      final size = b.bytes.compareTo(a.bytes);
      return size != 0 ? size : a.label.compareTo(b.label);
    });
    if (buckets.length <= 20) return buckets;
    var restBytes = 0;
    var restFiles = 0;
    for (final bucket in buckets.skip(20)) {
      restBytes += bucket.bytes;
      restFiles += bucket.files;
    }
    return [
      ...buckets.take(20),
      StorageBucket(
        'Other (${buckets.length - 20} groups)',
        restBytes,
        restFiles,
      ),
    ];
  }

  String path(SearchEntry entry) {
    final parts = <String>[entry.name];
    var parent = entry.file.parentId;
    while (parent != null) {
      final ancestor = snapshot[parent]!;
      parts.add(ancestor.name);
      parent = ancestor.file.parentId;
    }
    return parts.reversed.join('/');
  }

  return StorageUsage(
    bytes,
    files,
    bounded([
      for (final bucket in folders.entries)
        StorageBucket(
          bucket.key == null
              ? 'Files at account root'
              : snapshot[bucket.key]!.name,
          bucket.value.bytes,
          bucket.value.files,
        ),
    ]),
    bounded([
      for (final bucket in types.entries)
        StorageBucket(bucket.key, bucket.value.bytes, bucket.value.files),
    ]),
    [for (final entry in largest) StorageFile(path(entry), entry.file.size)],
    [
      for (final entry in oldestLarge)
        StorageDatedFile(
          path(entry),
          entry.file.size,
          entry.file.updatedAt!.toUtc(),
        ),
    ],
    unknownLargeDates,
  );
}
