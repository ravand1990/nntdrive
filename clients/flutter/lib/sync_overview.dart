// Device-local overview of everything that is not fully synchronized.
//
// The list is derived from a read-only plan that the Rust sync engine computes
// per folder: the same three-way reconciliation a real sync would apply, minus
// every write. Names, paths and reasons stay on this device; the backend only
// ever sees the opaque listing it already serves.

import 'dart:isolate';

import 'sync_controller.dart';

/// Orders one already bounded, device-local result without blocking UI sorting.
/// Only entries cross the isolate boundary: never a controller, inspector,
/// native handle or session. Input copying remains caller-side.
Future<List<UnsyncedEntry>> orderUnsyncedEntries(
    List<UnsyncedEntry> entries) async {
  // No comparator work exists for these cases, so avoid a worker startup.
  if (entries.length < 2) return List<UnsyncedEntry>.of(entries);
  return Isolate.run(() {
    final ordered = List<UnsyncedEntry>.of(entries);
    ordered.sort((a, b) {
      final byFolder = a.folderName.compareTo(b.folderName);
      if (byFolder != 0) return byFolder;
      final byStatus = a.status.index.compareTo(b.status.index);
      return byStatus != 0 ? byStatus : a.path.compareTo(b.path);
    });
    return ordered;
  });
}

typedef OverviewEntryOrderer = Future<List<UnsyncedEntry>> Function(
    List<UnsyncedEntry> entries);

/// One item that is not fully in sync, with the reason a user can act on.
enum UnsyncedStatus { cloudOnly, localOnly, pending, failed, conflict, skipped, blocked }

extension UnsyncedStatusText on UnsyncedStatus {
  /// Text label, never colour alone.
  String get label => switch (this) {
        UnsyncedStatus.cloudOnly => 'Cloud only',
        UnsyncedStatus.localOnly => 'Local only',
        UnsyncedStatus.pending => 'Pending',
        UnsyncedStatus.failed => 'Failed',
        UnsyncedStatus.conflict => 'Conflict',
        UnsyncedStatus.skipped => 'Skipped',
        UnsyncedStatus.blocked => 'Blocked',
      };
}

class UnsyncedEntry {
  const UnsyncedEntry({
    required this.status,
    required this.folderId,
    required this.folderName,
    required this.path,
    required this.reason,
    this.pathTo,
    this.size,
    this.isDirectory = false,
    this.lastAttempt,
    this.retryable = true,
  });

  final UnsyncedStatus status;
  final String folderId;
  final String folderName;

  /// Relative path inside the sync folder, never an absolute local path.
  final String path;
  final String reason;
  final String? pathTo;
  final int? size;
  final bool isDirectory;

  /// Time of the last completed sync attempt for this folder, when known.
  final String? lastAttempt;

  /// Folder-level blocked/skipped rows have nothing to retry.
  final bool retryable;

  String get displayName {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  String get displayFolderPath {
    final slash = path.lastIndexOf('/');
    return slash < 0 ? '' : path.substring(0, slash);
  }
}

class UnsyncedFolderSummary {
  const UnsyncedFolderSummary(this.folderId, this.folderName, this.counts);

  final String folderId;
  final String folderName;
  final Map<UnsyncedStatus, int> counts;

  int get total => counts.values.fold(0, (sum, value) => sum + value);
}

/// A folder that could not be inspected, or whose comparison needs a sync
/// first. It is always shown rather than silently reported as in sync.
class UnsyncedNotice {
  const UnsyncedNotice(this.folderName, this.message);

  final String folderName;
  final String message;
}

/// Snapshot-owned immutable projections of the retained, already ordered rows.
/// Each row is referenced in all/status/folder/combined lists, never re-sorted.
class OverviewEntryProjection {
  const OverviewEntryProjection._(this.entries, this.counts, this._byStatus,
      this._byFolder, this._byFolderStatus);

  final List<UnsyncedEntry> entries;
  final Map<UnsyncedStatus, int> counts;
  final Map<UnsyncedStatus, List<UnsyncedEntry>> _byStatus;
  final Map<String, List<UnsyncedEntry>> _byFolder;
  final Map<(String, UnsyncedStatus), List<UnsyncedEntry>> _byFolderStatus;

  List<UnsyncedEntry> filtered({UnsyncedStatus? status, String? folderId}) {
    if (folderId == null) {
      return status == null ? entries : _byStatus[status] ?? const [];
    }
    return status == null
        ? _byFolder[folderId] ?? const []
        : _byFolderStatus[(folderId, status)] ?? const [];
  }
}

Map<K, List<UnsyncedEntry>> _freezeProjection<K>(
        Map<K, List<UnsyncedEntry>> groups) =>
    Map<K, List<UnsyncedEntry>>.unmodifiable(groups.map(
        (key, rows) => MapEntry(key, List<UnsyncedEntry>.unmodifiable(rows))));

OverviewEntryProjection _projectUnsyncedEntries(List<UnsyncedEntry> entries) {
  final counts = <UnsyncedStatus, int>{};
  final byStatus = <UnsyncedStatus, List<UnsyncedEntry>>{};
  final byFolder = <String, List<UnsyncedEntry>>{};
  final byFolderStatus = <(String, UnsyncedStatus), List<UnsyncedEntry>>{};
  for (final entry in entries) {
    final status = entry.status;
    final folder = entry.folderId;
    counts[status] = (counts[status] ?? 0) + 1;
    (byStatus[status] ??= []).add(entry);
    (byFolder[folder] ??= []).add(entry);
    (byFolderStatus[(folder, status)] ??= []).add(entry);
  }
  return OverviewEntryProjection._(
      List<UnsyncedEntry>.unmodifiable(entries),
      Map<UnsyncedStatus, int>.unmodifiable(counts),
      _freezeProjection(byStatus),
      _freezeProjection(byFolder),
      _freezeProjection(byFolderStatus));
}

/// One entry-only projection worker per refresh, after the final ordering.
/// No controller, inspector, native handle or per-rebuild worker is captured.
/// Input transfer/copying and the retained projection references still cost RAM.
Future<OverviewEntryProjection> projectUnsyncedEntries(
    List<UnsyncedEntry> entries) async {
  // Empty input needs no scan or worker; nonempty input always runs off-isolate.
  if (entries.isEmpty) return _projectUnsyncedEntries(const []);
  return Isolate.run(() => _projectUnsyncedEntries(entries));
}

typedef OverviewEntryProjector = Future<OverviewEntryProjection> Function(
    List<UnsyncedEntry> entries);

class UnsyncedOverview {
  /// Synchronous compatibility constructor for small hand-built snapshots.
  /// Production uses the prepared worker result, not this caller-side scan.
  factory UnsyncedOverview({
    required List<UnsyncedEntry> entries,
    required List<UnsyncedFolderSummary> folders,
    required List<UnsyncedNotice> notices,
    required DateTime inspectedAt,
    bool truncated = false,
  }) => UnsyncedOverview._prepared(
      projection: _projectUnsyncedEntries(entries), folders: folders,
      notices: notices, inspectedAt: inspectedAt, truncated: truncated);

  UnsyncedOverview._prepared({
    required OverviewEntryProjection projection,
    required List<UnsyncedFolderSummary> folders,
    required List<UnsyncedNotice> notices,
    required this.inspectedAt,
    required this.truncated,
  }) : _projection = projection,
       folders = List<UnsyncedFolderSummary>.unmodifiable([
         for (final folder in folders)
           UnsyncedFolderSummary(folder.folderId, folder.folderName,
               Map<UnsyncedStatus, int>.unmodifiable(folder.counts)),
       ]),
       notices = List<UnsyncedNotice>.unmodifiable(notices);

  final OverviewEntryProjection _projection;
  List<UnsyncedEntry> get entries => _projection.entries;
  final List<UnsyncedFolderSummary> folders;
  final List<UnsyncedNotice> notices;
  final DateTime inspectedAt;
  final bool truncated;

  int get total => entries.length;
  Map<UnsyncedStatus, int> get counts => _projection.counts;

  List<UnsyncedEntry> filtered({UnsyncedStatus? status, String? folderId}) =>
      _projection.filtered(status: status, folderId: folderId);
}

typedef FolderInspector = Future<Map<String, dynamic>> Function(
    SyncFolderConfig folder);

/// Runs one read-only plan per enabled folder and maps it to user statuses.
///
/// Statuses come from the engine plan:
/// `upload` is local-only, `download`/`create_local_dir` are cloud-only, and
/// deletes, moves and revision adoption are pending operations. A path that
/// failed in the last completed attempt is reported as failed with that
/// reason, case-only collisions are blocked, and selective-sync exclusions are
/// listed as skipped. Folder-level storage access problems are blocked.
Future<UnsyncedOverview> buildUnsyncedOverview({
  required List<SyncFolderConfig> folders,
  required FolderInspector inspect,
  int maxEntries = 20000,
  OverviewEntryOrderer orderEntries = orderUnsyncedEntries,
  OverviewFolderMapper mapFolder = mapUnsyncedFolder,
  OverviewEntryProjector projectEntries = projectUnsyncedEntries,
}) async {
  // Freeze every folder before the first await, including later folders' reports.
  // No live config, controller, inspector closure or session reaches a worker.
  final frozen = [for (final folder in folders) _freezeOverviewFolder(folder)];
  final sources = List<SyncFolderConfig>.of(folders);
  final entries = <UnsyncedEntry>[];
  final summaries = <UnsyncedFolderSummary>[];
  final notices = <UnsyncedNotice>[];
  var truncated = false;
  for (var i = 0; i < frozen.length; i++) {
    final folder = frozen[i];
    Map<String, dynamic> plan = const {};
    var inspectionFailed = false;
    if (!folder.storageAccessRequired) {
      try {
        plan = await inspect(sources[i]);
      } catch (_) {
        inspectionFailed = true;
      }
    }
    final mapped = await mapFolder(
        folder, plan, maxEntries - entries.length, inspectionFailed);
    entries.addAll(mapped.entries);
    summaries.add(mapped.summary);
    notices.addAll(mapped.notices);
    truncated = truncated || mapped.truncated;
  }
  final ordered = await orderEntries(entries);
  final projection = await projectEntries(ordered);
  return UnsyncedOverview._prepared(
    projection: projection,
    folders: summaries,
    notices: notices,
    inspectedAt: DateTime.now(),
    truncated: truncated,
  );
}

/// Immutable, device-local mapping input; deliberately contains no native or UI
/// objects. Reports are frozen before inspection can suspend or mutate config.
class OverviewFolderInput {
  const OverviewFolderInput(this.id, this.name, this.lastSync,
      this.storageAccessRequired, this.excluded, this.lastReport);

  final String id;
  final String name;
  final String? lastSync;
  final bool storageAccessRequired;
  final List<String> excluded;
  final Map<String, dynamic>? lastReport;
}

// Copy only JSON-shaped report values; unrelated diagnostics/objects are omitted.
Object? _freezeReportValue(Object? value) {
  if (value is String || value is num || value is bool || value == null) return value;
  if (value is List) {
    return [for (final item in value) _freezeReportValue(item)];
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final key in value.keys)
        if (key is String) key: _freezeReportValue(value[key]),
    };
  }
  return null;
}

OverviewFolderInput _freezeOverviewFolder(SyncFolderConfig folder) =>
    OverviewFolderInput(
      folder.id, folder.name, folder.lastSync, folder.storageAccessRequired,
      List<String>.unmodifiable(folder.excluded),
      folder.lastReport == null ? null : <String, dynamic>{
        'item_errors': _freezeReportValue(folder.lastReport!['item_errors']),
        'skipped': _freezeReportValue(folder.lastReport!['skipped']),
      });

class OverviewFolderMapping {
  const OverviewFolderMapping(this.entries, this.summary, this.notices, this.truncated);
  final List<UnsyncedEntry> entries;
  final UnsyncedFolderSummary summary;
  final List<UnsyncedNotice> notices;
  final bool truncated;
}

typedef OverviewFolderMapper = Future<OverviewFolderMapping> Function(
    OverviewFolderInput folder, Map<String, dynamic> plan,
    int maxEntries, bool inspectionFailed);

/// One sequential worker per inspected folder, with a retained-row budget. The
/// existing native plan/report are still copied in full, not streamed batches.
/// The top-level dispatch captures only explicit sendable mapping inputs.
Future<OverviewFolderMapping> mapUnsyncedFolder(
    OverviewFolderInput folder, Map<String, dynamic> plan,
    int maxEntries, bool inspectionFailed) =>
    Isolate.run(() => _mapUnsyncedFolder(folder, plan, maxEntries, inspectionFailed));

OverviewFolderMapping _mapUnsyncedFolder(
    OverviewFolderInput folder, Map<String, dynamic> plan,
    int maxEntries, bool inspectionFailed) {
  final entries = <UnsyncedEntry>[];
  final notices = <UnsyncedNotice>[];
  var truncated = false;
  final failed = <String, String>{};
  final report = folder.lastReport;
  final itemErrors = report?['item_errors'];
  if (itemErrors is List) {
    for (final error in itemErrors) {
      if (error is! Map) continue;
      final paths = error['paths'];
      if (paths is! List) continue;
      final code = error['code'];
      final reason = _errorReason(code is String ? code : null);
      for (final path in paths) {
        if (path is String) failed[path] = reason;
      }
    }
  }

  if (folder.storageAccessRequired) {
    final blocked = UnsyncedEntry(
      status: UnsyncedStatus.blocked,
      folderId: folder.id,
      folderName: folder.name,
      path: '',
      isDirectory: true,
      retryable: false,
      reason:
          'Storage access is needed for this folder. Grant access and sync again.',
      lastAttempt: folder.lastSync,
    );
    if (entries.length < maxEntries) {
      entries.add(blocked);
    } else {
      truncated = true;
    }
    return _mappedFolder(folder, entries, notices, truncated);
  }

  final folderEntries = <UnsyncedEntry>[];
  void add(UnsyncedEntry entry) {
    if (entries.length + folderEntries.length >= maxEntries) {
      truncated = true;
      return;
    }
    folderEntries.add(entry);
  }

  for (final excluded in folder.excluded) {
    final clean = excluded.replaceAll('\\', '/');
    if (clean.isEmpty) continue;
    add(UnsyncedEntry(
      status: UnsyncedStatus.skipped,
      folderId: folder.id,
      folderName: folder.name,
      path: clean,
      isDirectory: !clean.contains('.'),
      retryable: false,
      reason: 'Excluded from sync on this device (selective sync).',
      lastAttempt: folder.lastSync,
    ));
  }

  final skipped = report?['skipped'];
  if (skipped is List) {
    for (final item in skipped) {
      if (item is! List || item.isEmpty || item.first is! String) continue;
      final reason = item.length > 1 ? item[1] : null;
      add(UnsyncedEntry(
        status: UnsyncedStatus.skipped,
        folderId: folder.id,
        folderName: folder.name,
        path: item.first as String,
        reason: reason is String && reason.isNotEmpty
            ? 'Skipped: $reason.'
            : 'Skipped by the sync engine.',
        retryable: false,
        lastAttempt: folder.lastSync,
      ));
    }
  }

  try {
    if (inspectionFailed) throw const FormatException();
    final blockReason = _filesystemBlockReason(plan['filesystem_blocked']);
    if (blockReason != null) {
      // No partial plan or historical skip list describes an unreadable tree.
      // Count one root row, not unobserved files or inferred deletions.
      folderEntries.clear();
      add(UnsyncedEntry(
        status: UnsyncedStatus.blocked,
        folderId: folder.id,
        folderName: folder.name,
        path: '',
        isDirectory: true,
        retryable: false,
        reason: blockReason,
        lastAttempt: folder.lastSync,
      ));
      entries.addAll(folderEntries);
      return _mappedFolder(folder, entries, notices, truncated);
    }
    final blockedPaths = <String>{
      for (final pair in _stringPairs(plan['case_collisions'])) ...[pair.$1, pair.$2]
    };
    for (final item in _planItems(plan['items'])) {
      final kind = item.$1;
      final path = item.$2;
      final pathTo = item.$3;
      final size = item.$4;
      final isDirectory = item.$5;
      final mapped = _statusFor(kind);
      if (mapped == null) continue;

      if (blockedPaths.contains(path)) {
        add(UnsyncedEntry(
          status: UnsyncedStatus.blocked,
          folderId: folder.id,
          folderName: folder.name,
          path: path,
          size: size,
          isDirectory: isDirectory,
          reason:
              'Two names differ only by letter case; one path is blocked until they are renamed.',
          lastAttempt: folder.lastSync,
        ));
        continue;
      }

      final failure = failed[path];
      add(UnsyncedEntry(
        status: failure != null ? UnsyncedStatus.failed : mapped,
        folderId: folder.id,
        folderName: folder.name,
        path: path,
        pathTo: pathTo,
        size: size,
        isDirectory: isDirectory,
        reason: failure ?? _reasonFor(kind, pathTo),
        lastAttempt: folder.lastSync,
      ));
    }
    if (plan['folder_moves_pending'] == true) {
      notices.add(UnsyncedNotice(
        folder.name,
        'A folder move is still pending. Sync this folder first so every item can be listed at its new path.',
      ));
    }
    if (plan['journal_available'] == false) {
      notices.add(UnsyncedNotice(
        folder.name,
        'No completed sync exists for this folder yet, so every item is compared as new.',
      ));
    }
    if (plan['truncated'] == true) truncated = true;
  } catch (_) {
    notices.add(UnsyncedNotice(
      folder.name,
      'This folder could not be compared right now. Sync it and refresh; it is not reported as in sync.',
    ));
  }

  // Keep mapping order until the single final worker sort. Sorting each
  // folder here would duplicate the final ordering.
  entries.addAll(folderEntries);

  return _mappedFolder(folder, entries, notices, truncated);
}

OverviewFolderMapping _mappedFolder(OverviewFolderInput folder,
    List<UnsyncedEntry> entries, List<UnsyncedNotice> notices, bool truncated) {
  final counts = <UnsyncedStatus, int>{};
  for (final entry in entries) {
    counts[entry.status] = (counts[entry.status] ?? 0) + 1;
  }
  return OverviewFolderMapping(entries,
      UnsyncedFolderSummary(folder.id, folder.name, counts), notices, truncated);
}

UnsyncedStatus? _statusFor(String kind) => switch (kind) {
      'upload' || 'create_remote_dir' => UnsyncedStatus.localOnly,
      'download' || 'create_local_dir' => UnsyncedStatus.cloudOnly,
      'delete_local' ||
      'delete_remote' ||
      'rename_local' ||
      'move_remote' ||
      'adopt_revision' =>
        UnsyncedStatus.pending,
      'conflict' => UnsyncedStatus.conflict,
      _ => null,
    };

String _reasonFor(String kind, String? pathTo) => switch (kind) {
      'upload' => 'Not uploaded to the account yet.',
      'create_remote_dir' => 'This folder exists only on this device.',
      'download' => 'Exists in the account, not on this device yet.',
      'create_local_dir' => 'This folder exists only in the account.',
      'delete_local' => 'The account copy was removed; the local copy is still here.',
      'delete_remote' => 'The local copy was removed; the account copy is still there.',
      'rename_local' => pathTo == null
          ? 'A rename is waiting for the next sync.'
          : 'Will be renamed to $pathTo.',
      'move_remote' => pathTo == null
          ? 'A move is waiting for the next sync.'
          : 'Will be moved to $pathTo in the account.',
      'adopt_revision' =>
        'Both sides have identical content; the recorded revision is being updated.',
      'conflict' =>
        'Both sides changed. Choose keep mine, keep theirs or keep both in Sync.',
      _ => 'Waiting for the next sync.',
    };

String? _filesystemBlockReason(Object? code) => switch (code) {
      'permission_denied' =>
        'This folder or a path inside it cannot be read. Check storage permissions, grant access if needed, then refresh.',
      'not_found' =>
        'This folder or a path inside it is missing. Check that the folder is available, then refresh.',
      'not_a_directory' =>
        'The configured folder or a path inside it is no longer a directory. Check the local folder location, then refresh.',
      'io' =>
        'The complete folder could not be read. Check the drive and local folder access, then refresh.',
      _ => null,
    };

String _errorReason(String? code) => switch (code) {
      'io' => 'Reading or writing this file failed. Check that it is not in use.',
      'journal' => 'The local sync record could not be updated.',
      'remote' => 'The server rejected or failed this operation.',
      'unsafe_path' => 'This path is not safe to sync.',
      'missing_source' =>
        'The account folder moved but the local source is missing.',
      'case_collision' =>
        'Two names differ only by letter case. Rename one of them.',
      'unverified_revision' =>
        'The account revision could not be verified, so nothing was overwritten.',
      _ => 'The last sync attempt failed for this item.',
    };

Iterable<(String, String)> _stringPairs(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    if (item is List && item.length >= 2 && item[0] is String && item[1] is String) {
      yield (item[0] as String, item[1] as String);
    }
  }
}

Iterable<(String, String, String?, int?, bool)> _planItems(Object? value) sync* {
  if (value is! List) return;
  for (final item in value) {
    if (item is! Map) continue;
    final kind = item['kind'];
    final path = item['path'];
    if (kind is! String || path is! String || path.isEmpty) continue;
    yield (
      kind,
      path,
      item['path_to'] is String ? item['path_to'] as String : null,
      item['size'] is int ? item['size'] as int : null,
      item['is_dir'] == true,
    );
  }
}
