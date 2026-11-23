import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

enum SyncDiskState { complete, incomplete, unavailable, overlap }

/// One configured root, in configuration order. No paths or raw IO errors are
/// returned. There is deliberately no sum across roots or with cache/account.
class SyncDiskRootUsage {
  const SyncDiskRootUsage(this.state, this.bytes, this.files, this.skipped);
  final SyncDiskState state;
  final int bytes;
  final int files;
  final int skipped;
}

class SyncDiskUsage {
  SyncDiskUsage(List<SyncDiskRootUsage> roots)
    : roots = List.unmodifiable(roots);
  final List<SyncDiskRootUsage> roots;
}

/// All metadata/listing IO runs here, never in the controller's lexical context.
/// Limits are shared across roots. Time is cooperative between OS operations,
/// not a deadline interrupting a stalled filesystem call. No contents/journals
/// are opened; excluded/local-only/hidden regular files still consume disk.
Future<SyncDiskUsage> runSyncDiskUsage(
  List<String> roots, {
  int maxEntries = 10000,
  Duration maxTime = const Duration(seconds: 2),
}) => Isolate.run(() => _measure(roots, maxEntries, maxTime));

Future<bool> _safe(String path, FileSystemEntityType expected) async {
  final root = p.rootPrefix(path);
  var current = root;
  for (final part in p.split(path).skip(1)) {
    current = p.join(current, part);
    final type = await FileSystemEntity.type(current, followLinks: false);
    if (type !=
        (p.equals(current, path) ? expected : FileSystemEntityType.directory)) {
      return false;
    }
  }
  if (await FileSystemEntity.type(path, followLinks: false) != expected) {
    return false;
  }
  final canonical = expected == FileSystemEntityType.directory
      ? await Directory(path).resolveSymbolicLinks()
      : await File(path).resolveSymbolicLinks();
  return p.equals(canonical, path);
}

Future<SyncDiskUsage> _measure(
  List<String> input,
  int maxEntries,
  Duration maxTime,
) async {
  if (input.length > 20 ||
      maxEntries < 0 ||
      maxEntries > 10000 ||
      maxTime.isNegative ||
      maxTime > const Duration(seconds: 2)) {
    throw StateError('Sync-folder accounting unavailable');
  }
  final watch = Stopwatch()..start();
  var visited = 0;
  bool exhausted() => visited >= maxEntries || watch.elapsed >= maxTime;
  // Reject relative/non-normal paths instead of silently repairing traversal.
  final roots = [
    for (final path in input)
      p.isAbsolute(path) && p.normalize(path) == path ? path : null,
  ];
  final result = <SyncDiskRootUsage>[];
  for (var i = 0; i < roots.length; i++) {
    final root = roots[i];
    if (root == null) {
      result.add(const SyncDiskRootUsage(SyncDiskState.unavailable, 0, 0, 0));
      continue;
    }
    // Refuse both members of overlapping/equal configured roots, even if one
    // is unavailable. Never silently count the same subtree in two rows.
    if (roots.indexed.any(
      (other) =>
          other.$1 != i &&
          other.$2 != null &&
          (p.equals(root, other.$2!) ||
              p.isWithin(root, other.$2!) ||
              p.isWithin(other.$2!, root)),
    )) {
      result.add(const SyncDiskRootUsage(SyncDiskState.overlap, 0, 0, 0));
      continue;
    }
    var bytes = 0;
    var files = 0;
    var skipped = 0;
    var state = SyncDiskState.complete;
    try {
      if (exhausted()) {
        result.add(const SyncDiskRootUsage(SyncDiskState.incomplete, 0, 0, 0));
        continue;
      }
      if (!await _safe(root, FileSystemEntityType.directory)) {
        result.add(const SyncDiskRootUsage(SyncDiskState.unavailable, 0, 0, 0));
        continue;
      }
      final pending = <String>[root];
      while (pending.isNotEmpty) {
        if (exhausted()) {
          state = SyncDiskState.incomplete;
          break;
        }
        final directory = pending.removeLast();
        if (!await _safe(directory, FileSystemEntityType.directory)) {
          skipped++;
          state = SyncDiskState.incomplete;
          continue;
        }
        await for (final entity in Directory(
          directory,
        ).list(followLinks: false)) {
          if (exhausted()) {
            state = SyncDiskState.incomplete;
            break;
          }
          visited++;
          final path = entity.path;
          if (!p.isWithin(root, path)) {
            skipped++;
            state = SyncDiskState.incomplete;
            continue;
          }
          final type = await FileSystemEntity.type(path, followLinks: false);
          if ((type != FileSystemEntityType.file &&
                  type != FileSystemEntityType.directory) ||
              !await _safe(path, type)) {
            skipped++;
            state = SyncDiskState.incomplete;
            continue;
          }
          if (type == FileSystemEntityType.directory) {
            pending.add(path);
          } else {
            final length = await File(path).length();
            if (!await _safe(path, FileSystemEntityType.file) ||
                length < 0 ||
                bytes > 0x7fffffffffffffff - length) {
              skipped++;
              state = SyncDiskState.incomplete;
              continue;
            }
            bytes += length;
            files++;
          }
        }
        if (exhausted()) {
          state = SyncDiskState.incomplete;
          break;
        }
      }
      if (!await _safe(root, FileSystemEntityType.directory)) {
        state = SyncDiskState.unavailable;
        bytes = files = 0;
      }
      if (watch.elapsed >= maxTime) state = SyncDiskState.incomplete;
    } catch (_) {
      // No filesystem paths/diagnostics escape to UI, persistence or telemetry.
      state = files == 0 ? SyncDiskState.unavailable : SyncDiskState.incomplete;
    }
    result.add(SyncDiskRootUsage(state, bytes, files, skipped));
  }
  return SyncDiskUsage(result);
}
