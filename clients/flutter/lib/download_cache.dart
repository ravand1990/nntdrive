// Bounded offline download cache (#82).
//
// Files the user pins stay on this device so they can be opened without the
// network; everything else in the cache is unowned scratch space that is
// evicted least-recently-used first once the cache exceeds its limit.
//
// Safety rules this file exists to enforce:
//   * The cache only ever touches files inside its own root directory. It never
//     reads or deletes a sync folder, a user's saved copy, or a local-only file.
//   * A cache entry stores an opaque file ID, a revision ID, a validated file
//     name, byte count, timestamps and the pin flag — never a path taken from
//     anywhere else, so a tampered index cannot point outside the root.
//   * Symlinks are never followed: an entry whose name resolves to a link is
//     dropped from the index instead of having its target read or deleted.
//   * Writes land in a `.part` file and are renamed into place, so an
//     interrupted download can only leave disposable scratch bytes behind.
//   * A pinned entry is never evicted, and eviction happens after a store
//     completes, so it cannot pull bytes out from under a running download.
//
// One consequence is deliberate: if every remaining byte belongs to a pinned
// copy or to the revision that was just stored, the cache stays above its limit
// instead of deleting content the user asked to keep. The next store evicts the
// older unpinned copy.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Cap for the whole cache. Chosen to be useful and still small enough that a
/// desktop or phone does not lose meaningful space to downloaded copies.
const int downloadCacheDefaultLimitBytes = 2 * 1024 * 1024 * 1024;

/// Hard cap on index rows, so a cache cannot grow an unbounded metadata list
/// out of many tiny files before the byte limit is reached.
const int downloadCacheMaxEntries = 5000;

const String _indexFileName = 'index.json';
const String _partSuffix = '.part';
final RegExp _cacheNamePattern = RegExp(r'^[0-9a-f]{32}\.bin$');

/// One cached revision. Identity is the server's opaque file and revision IDs;
/// [fileName] is derived from them and never supplied by a listing or the user.
class CachedDownload {
  const CachedDownload({
    required this.fileId,
    required this.revisionId,
    required this.fileName,
    required this.sizeBytes,
    required this.storedAt,
    required this.lastUsedAt,
    required this.pinned,
  });

  final String fileId;
  final String revisionId;
  final String fileName;
  final int sizeBytes;
  final DateTime storedAt;
  final DateTime lastUsedAt;
  final bool pinned;

  CachedDownload copyWith({DateTime? lastUsedAt, bool? pinned}) =>
      CachedDownload(
        fileId: fileId,
        revisionId: revisionId,
        fileName: fileName,
        sizeBytes: sizeBytes,
        storedAt: storedAt,
        lastUsedAt: lastUsedAt ?? this.lastUsedAt,
        pinned: pinned ?? this.pinned,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'fileId': fileId,
    'revisionId': revisionId,
    'fileName': fileName,
    'sizeBytes': sizeBytes,
    'storedAt': storedAt.toIso8601String(),
    'lastUsedAt': lastUsedAt.toIso8601String(),
    'pinned': pinned,
  };

  /// Rejects anything that is not exactly the shape this cache wrote, so a
  /// hand-edited or truncated index cannot introduce a foreign path.
  static CachedDownload? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final fileId = raw['fileId'];
    final revisionId = raw['revisionId'];
    final fileName = raw['fileName'];
    final sizeBytes = raw['sizeBytes'];
    final storedAt = DateTime.tryParse('${raw['storedAt']}');
    final lastUsedAt = DateTime.tryParse('${raw['lastUsedAt']}');
    final pinned = raw['pinned'];
    if (fileId is! String || fileId.isEmpty || fileId.length > 200) return null;
    if (revisionId is! String ||
        revisionId.isEmpty ||
        revisionId.length > 200) {
      return null;
    }
    if (fileName is! String || !_cacheNamePattern.hasMatch(fileName)) {
      return null;
    }
    if (sizeBytes is! int || sizeBytes < 0) return null;
    if (storedAt == null || lastUsedAt == null) return null;
    if (pinned is! bool) return null;
    return CachedDownload(
      fileId: fileId,
      revisionId: revisionId,
      fileName: fileName,
      sizeBytes: sizeBytes,
      storedAt: storedAt,
      lastUsedAt: lastUsedAt,
      pinned: pinned,
    );
  }
}

/// What the cache holds right now, in plain numbers the UI can print.
class CacheUsage {
  const CacheUsage({
    required this.limitBytes,
    required this.usedBytes,
    required this.pinnedBytes,
  });

  final int limitBytes;
  final int usedBytes;
  final int pinnedBytes;

  /// Bytes that can still be written inside the limit before eviction starts.
  int get headroomBytes => usedBytes >= limitBytes ? 0 : limitBytes - usedBytes;
}

/// Read-only filesystem observation of indexed cached revisions, not allocated
/// disk blocks or a whole-directory total. Scratch/orphan/index bytes are excluded.
class MeasuredCacheUsage {
  const MeasuredCacheUsage({
    required this.bytes,
    required this.copies,
    required this.pinnedBytes,
    required this.pinnedCopies,
    required this.excludedCopies,
  });

  final int bytes;
  final int copies;
  final int pinnedBytes;
  final int pinnedCopies;
  final int excludedCopies;
  int get unpinnedBytes => bytes - pinnedBytes;
  int get unpinnedCopies => copies - pinnedCopies;
}

/// Result of one eviction or cleanup pass.
class CacheCleanup {
  const CacheCleanup({
    required this.removedEntries,
    required this.freedBytes,
    required this.keptPinnedEntries,
  });

  static const CacheCleanup none = CacheCleanup(
    removedEntries: 0,
    freedBytes: 0,
    keptPinnedEntries: 0,
  );

  final int removedEntries;
  final int freedBytes;

  /// Pinned entries that were candidates-free: they stayed even though the
  /// limit would otherwise have removed them.
  final int keptPinnedEntries;

  bool get removedAnything => removedEntries > 0;
}

/// What [DownloadCache.open] found on disk.
class CacheOpenReport {
  const CacheOpenReport({
    required this.recoveredCorruptIndex,
    required this.droppedEntries,
    required this.removedOrphanFiles,
    required this.discardedPartialFiles,
  });

  /// True when the index could not be parsed. Orphan cleanup is skipped in that
  /// case: without the index a file might be pinned, so the bytes stay.
  final bool recoveredCorruptIndex;
  final int droppedEntries;
  final int removedOrphanFiles;
  final int discardedPartialFiles;
}

/// The device-local download cache. One instance per account session.
class DownloadCache {
  DownloadCache({
    required this.root,
    int limitBytes = downloadCacheDefaultLimitBytes,
    DateTime Function()? clock,
  }) : assert(limitBytes > 0),
       _limitBytes = limitBytes,
       _clock = clock ?? DateTime.now;

  final Directory root;
  final DateTime Function() _clock;

  /// Current ceiling for the whole cache. Changed through [setLimit], which
  /// evicts immediately so the reported usage always matches the limit.
  int _limitBytes;

  int get limitBytes => _limitBytes;

  final Map<String, CachedDownload> _entries = <String, CachedDownload>{};
  bool _opened = false;
  bool _corruptIndex = false;
  bool _busy = false;
  final List<Completer<void>> _waiters = <Completer<void>>[];

  /// File name of the revision stored or adopted last in this instance.
  /// Limit changes protect it so lowering the limit cannot evict the copy
  /// that just finished downloading. Explicit cleanup/unpin remains allowed.
  String? _lastStoredName;

  bool get isOpen => _opened;
  bool get recoveredCorruptIndex => _corruptIndex;

  /// Most recently used first, which is also the order the UI lists.
  List<CachedDownload> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.lastUsedAt.compareTo(a.lastUsedAt));
    return List<CachedDownload>.unmodifiable(list);
  }

  int get entryCount => _entries.length;

  CacheUsage get usage {
    var used = 0;
    var pinned = 0;
    for (final entry in _entries.values) {
      used += entry.sizeBytes;
      if (entry.pinned) pinned += entry.sizeBytes;
    }
    return CacheUsage(
      limitBytes: limitBytes,
      usedBytes: used,
      pinnedBytes: pinned,
    );
  }

  /// Measures only the existing bounded index under the cache operation queue.
  /// Never reopens/reconciles the cache, scans directories, reads contents or
  /// writes metadata. Pin flags are frozen by serialization with cache writers.
  /// External changes can make this a mixed-time observation, not an atomic or
  /// integrity-verified snapshot. Stable links/non-files are never followed.
  Future<MeasuredCacheUsage> measureUsage() => _serial(() async {
    _requireOpen();
    if (_corruptIndex || _entries.length > downloadCacheMaxEntries) {
      throw StateError('Cache accounting unavailable');
    }
    Future<void> checkRoot() async {
      var path = p.normalize(p.absolute(root.path));
      while (true) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw StateError('Cache accounting unavailable');
        }
        final parent = p.dirname(path);
        if (parent == path) break;
        path = parent;
      }
    }

    await checkRoot();
    var bytes = 0;
    var copies = 0;
    var pinnedBytes = 0;
    var pinnedCopies = 0;
    var excluded = 0;
    for (final entry in _entries.values) {
      final path = fileFor(entry).path;
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        excluded++;
        continue;
      }
      final size = await File(path).length();
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('Cache accounting changed during measurement');
      }
      if (size < 0 || bytes > 0x7fffffffffffffff - size) {
        throw StateError('Cache accounting unavailable');
      }
      bytes += size;
      copies++;
      if (entry.pinned) {
        pinnedBytes += size;
        pinnedCopies++;
      }
    }
    await checkRoot();
    return MeasuredCacheUsage(
      bytes: bytes,
      copies: copies,
      pinnedBytes: pinnedBytes,
      pinnedCopies: pinnedCopies,
      excludedCopies: excluded,
    );
  });

  static String _key(String fileId, String revisionId) =>
      '$fileId\u0000$revisionId';

  /// Cache file name for a revision: derived, never taken from a listing.
  static String fileNameFor(String fileId, String revisionId) {
    final digest = sha256
        .convert(utf8.encode('$fileId\n$revisionId'))
        .toString();
    return '${digest.substring(0, 32)}.bin';
  }

  File fileFor(CachedDownload entry) => File(p.join(root.path, entry.fileName));

  CachedDownload? find(String fileId, {String? revisionId}) {
    if (revisionId != null) return _entries[_key(fileId, revisionId)];
    for (final entry in _entries.values) {
      if (entry.fileId == fileId) return entry;
    }
    return null;
  }

  /// A local path for an existing, verified cached revision, or null.
  File? localFile(String fileId, String revisionId) {
    final entry = find(fileId, revisionId: revisionId);
    if (entry == null) return null;
    final file = fileFor(entry);
    if (_isRegularFile(file.path)) return file;
    return null;
  }

  /// One owned operation at a time. Waiters get a completer created by their
  /// own caller, so the queue never chains onto a future from another zone
  /// (which would otherwise stall under a test's fake-async zone) and ownership
  /// is handed directly to the next waiter instead of bouncing through a
  /// temporarily-idle state.
  Future<T> _serial<T>(Future<T> Function() action) async {
    await _acquire();
    try {
      return await action();
    } finally {
      _release();
    }
  }

  Future<void> _acquire() {
    if (!_busy) {
      _busy = true;
      return Future<void>.value();
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    return waiter.future;
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _busy = false;
    }
  }

  /// Reads the index and reconciles it with the directory.
  ///
  /// Entries whose file is gone, is not a regular file, or has an unexpected
  /// size are dropped. Leftover `.part` files are always disposable. Orphan
  /// `.bin` files are removed only after a clean index read.
  Future<CacheOpenReport> open() => _serial(() async {
    var dropped = 0;
    var orphans = 0;
    var partials = 0;
    _entries.clear();
    _corruptIndex = false;
    await root.create(recursive: true);

    final indexFile = File(p.join(root.path, _indexFileName));
    if (await indexFile.exists()) {
      Map<String, dynamic>? decoded;
      try {
        final raw = jsonDecode(await indexFile.readAsString());
        if (raw is Map<String, dynamic>) decoded = raw;
      } catch (_) {
        decoded = null;
      }
      final rows = decoded?['entries'];
      if (decoded == null || rows is! List) {
        _corruptIndex = true;
      } else {
        final seenNames = <String>{};
        for (final raw in rows) {
          final entry = CachedDownload.fromJson(raw);
          if (entry == null || !seenNames.add(entry.fileName)) {
            dropped++;
            continue;
          }
          final path = fileFor(entry).path;
          final type = await FileSystemEntity.type(path, followLinks: false);
          if (type != FileSystemEntityType.file ||
              await fileFor(entry).length() != entry.sizeBytes) {
            dropped++;
            continue;
          }
          _entries[_key(entry.fileId, entry.revisionId)] = entry;
        }
      }
    }

    await for (final entity in root.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (entity is! File) continue;
      if (name.endsWith(_partSuffix)) {
        try {
          await entity.delete();
          partials++;
        } catch (_) {
          // A leftover scratch file that cannot be removed is harmless.
        }
        continue;
      }
      if (!_cacheNamePattern.hasMatch(name)) continue;
      final referenced = _entries.values.any((e) => e.fileName == name);
      if (referenced) continue;
      if (_corruptIndex) continue;
      try {
        await entity.delete();
        orphans++;
      } catch (_) {
        // Never fail open() because one stale file resisted deletion.
      }
    }

    _opened = true;
    return CacheOpenReport(
      recoveredCorruptIndex: _corruptIndex,
      droppedEntries: dropped,
      removedOrphanFiles: orphans,
      discardedPartialFiles: partials,
    );
  });

  /// Adds a copy of [source] to the cache. The caller keeps its own file.
  Future<CachedDownload> store({
    required String fileId,
    required String revisionId,
    required File source,
    bool pinned = false,
  }) => _serial(() async {
    _requireOpen();
    final name = fileNameFor(fileId, revisionId);
    final destination = File(p.join(root.path, name));
    final part = File('${destination.path}$_partSuffix');
    await root.create(recursive: true);
    await source.copy(part.path);
    final length = await part.length();
    await part.rename(destination.path);
    final now = _clock();
    final entry = CachedDownload(
      fileId: fileId,
      revisionId: revisionId,
      fileName: name,
      sizeBytes: length,
      storedAt: now,
      lastUsedAt: now,
      pinned: pinned,
    );
    _entries[_key(fileId, revisionId)] = entry;
    _lastStoredName = name;
    await _enforceLimitLocked(protect: name);
    await _writeIndex();
    return _entries[_key(fileId, revisionId)] ?? entry;
  });

  /// Moves a file that already lives directly inside the cache root into place
  /// without copying it, which is how a native download lands in the cache.
  Future<CachedDownload> adopt({
    required String fileId,
    required String revisionId,
    required File source,
    bool pinned = false,
  }) => _serial(() async {
    _requireOpen();
    final sourcePath = p.canonicalize(source.path);
    final rootPath = p.canonicalize(root.path);
    if (p.dirname(sourcePath) != rootPath) {
      throw ArgumentError(
        'Only a file directly inside the cache can be adopted',
      );
    }
    if (!_isRegularFile(sourcePath)) {
      throw ArgumentError('The adopted file is not a regular file');
    }
    final name = fileNameFor(fileId, revisionId);
    final destination = File(p.join(root.path, name));
    if (sourcePath != p.canonicalize(destination.path)) {
      await source.rename(destination.path);
    }
    final length = await destination.length();
    final now = _clock();
    final entry = CachedDownload(
      fileId: fileId,
      revisionId: revisionId,
      fileName: name,
      sizeBytes: length,
      storedAt: now,
      lastUsedAt: now,
      pinned: pinned,
    );
    _entries[_key(fileId, revisionId)] = entry;
    _lastStoredName = name;
    await _enforceLimitLocked(protect: name);
    await _writeIndex();
    return entry;
  });

  /// Marks a cached revision as used now, which moves it to the front of the
  /// LRU order. Returns null when the revision is not cached.
  Future<CachedDownload?> touch(String fileId, String revisionId) =>
      _serial(() async {
        _requireOpen();
        final entry = _entries[_key(fileId, revisionId)];
        if (entry == null) return null;
        final updated = entry.copyWith(lastUsedAt: _clock());
        _entries[_key(fileId, revisionId)] = updated;
        await _writeIndex();
        return updated;
      });

  /// Pins or unpins a cached revision. Unpinning makes it evictable and runs
  /// the limit immediately, so the reported usage matches what was asked for.
  Future<CachedDownload?> setPinned(
    String fileId,
    String revisionId,
    bool pinned,
  ) => _serial(() async {
    _requireOpen();
    final entry = _entries[_key(fileId, revisionId)];
    if (entry == null) return null;
    final updated = entry.copyWith(pinned: pinned, lastUsedAt: _clock());
    _entries[_key(fileId, revisionId)] = updated;
    if (!pinned) await _enforceLimitLocked();
    await _writeIndex();
    return _entries[_key(fileId, revisionId)];
  });

  /// Removes one cached revision. Pinned entries are removed only when
  /// [evenIfPinned] is set, which the UI uses for an explicit "remove".
  Future<bool> remove(
    String fileId,
    String revisionId, {
    bool evenIfPinned = true,
  }) => _serial(() async {
    _requireOpen();
    final entry = _entries[_key(fileId, revisionId)];
    if (entry == null) return false;
    if (entry.pinned && !evenIfPinned) return false;
    await _deleteEntry(entry);
    _entries.remove(_key(fileId, revisionId));
    await _writeIndex();
    return true;
  });

  /// Removes every unpinned entry and reports exactly what it reclaimed.
  Future<CacheCleanup> clearUnpinned() => _serial(() async {
    _requireOpen();
    var removed = 0;
    var freed = 0;
    final pinned = _entries.values.where((e) => e.pinned).length;
    for (final entry in _entries.values.where((e) => !e.pinned).toList()) {
      final deleted = await _deleteEntry(entry);
      _entries.remove(_key(entry.fileId, entry.revisionId));
      removed++;
      if (deleted) freed += entry.sizeBytes;
    }
    await _writeIndex();
    return CacheCleanup(
      removedEntries: removed,
      freedBytes: freed,
      keptPinnedEntries: pinned,
    );
  });

  /// Applies a new whole-cache limit and evicts down to it immediately.
  ///
  /// Only unpinned scratch copies are ever evicted, and the revision stored or
  /// adopted last is protected, so a limit change cannot pull the copy a
  /// download just finished. A limit below the pinned or just-stored bytes
  /// leaves the cache above the limit and reports how many pinned copies were
  /// kept. Rejects a non-positive limit before changing anything.
  Future<CacheCleanup> setLimit(int bytes) => _serial(() async {
    _requireOpen();
    if (bytes <= 0) {
      throw ArgumentError.value(bytes, 'bytes', 'must be positive');
    }
    _limitBytes = bytes;
    return _enforceLimitLocked(protect: _lastStoredName);
  });

  /// Evicts least-recently-used unpinned entries until the cache fits its
  /// limit and entry cap.
  Future<CacheCleanup> enforceLimit({String? protect}) =>
      _serial(() => _enforceLimitLocked(protect: protect));

  /// The eviction pass itself. Callers already hold the serial queue, so this
  /// must not re-enter [_serial].
  Future<CacheCleanup> _enforceLimitLocked({String? protect}) async {
    _requireOpen();
    var removed = 0;
    var freed = 0;
    var usageNow = usage;
    var count = _entries.length;
    final pinnedCount = _entries.values.where((e) => e.pinned).length;

    bool overLimit() =>
        usageNow.usedBytes > limitBytes || count > downloadCacheMaxEntries;

    while (overLimit()) {
      CachedDownload? victim;
      for (final entry in _entries.values) {
        if (entry.pinned || entry.fileName == protect) continue;
        if (victim == null || entry.lastUsedAt.isBefore(victim.lastUsedAt)) {
          victim = entry;
        }
      }
      if (victim == null) break; // everything left is pinned or protected
      final deleted = await _deleteEntry(victim);
      _entries.remove(_key(victim.fileId, victim.revisionId));
      removed++;
      count--;
      if (deleted) {
        freed += victim.sizeBytes;
        usageNow = CacheUsage(
          limitBytes: limitBytes,
          usedBytes: usageNow.usedBytes - victim.sizeBytes,
          pinnedBytes: usageNow.pinnedBytes,
        );
      } else {
        usageNow = usage;
      }
    }
    if (removed > 0) await _writeIndex();
    return CacheCleanup(
      removedEntries: removed,
      freedBytes: freed,
      keptPinnedEntries: pinnedCount,
    );
  }

  Future<bool> _deleteEntry(CachedDownload entry) async {
    final file = fileFor(entry);
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        // Never touch what a link points at; dropping the index row is enough.
        return false;
      }
      if (type != FileSystemEntityType.file) return false;
      await file.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeIndex() async {
    final payload = jsonEncode(<String, dynamic>{
      'version': 1,
      'entries': _entries.values.map((e) => e.toJson()).toList(),
    });
    final target = File(p.join(root.path, _indexFileName));
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    await temp.rename(target.path);
  }

  void _requireOpen() {
    if (!_opened) throw StateError('Open the download cache before using it');
  }

  bool _isRegularFile(String path) =>
      FileSystemEntity.typeSync(path, followLinks: false) ==
      FileSystemEntityType.file;
}
