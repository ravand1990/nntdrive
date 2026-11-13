// Device-local overview of everything that is not fully synchronized.
//
// The list is derived from a read-only plan that the Rust sync engine computes
// per folder: the same three-way reconciliation a real sync would apply, minus
// every write. Names, paths and reasons stay on this device; the backend only
// ever sees the opaque listing it already serves.

import 'sync_controller.dart';

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

class UnsyncedOverview {
  UnsyncedOverview({
    required this.entries,
    required this.folders,
    required this.notices,
    required this.inspectedAt,
    this.truncated = false,
  });

  final List<UnsyncedEntry> entries;
  final List<UnsyncedFolderSummary> folders;
  final List<UnsyncedNotice> notices;
  final DateTime inspectedAt;
  final bool truncated;

  int get total => entries.length;

  Map<UnsyncedStatus, int> get counts {
    final out = <UnsyncedStatus, int>{};
    for (final entry in entries) {
      out[entry.status] = (out[entry.status] ?? 0) + 1;
    }
    return out;
  }

  List<UnsyncedEntry> filtered({UnsyncedStatus? status, String? folderId}) =>
      entries
          .where((entry) =>
              (status == null || entry.status == status) &&
              (folderId == null || entry.folderId == folderId))
          .toList();
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
}) async {
  final entries = <UnsyncedEntry>[];
  final summaries = <UnsyncedFolderSummary>[];
  final notices = <UnsyncedNotice>[];
  var truncated = false;

  for (final folder in folders) {
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
      summaries.add(_summary(folder, [blocked]));
      continue;
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
      final plan = await inspect(folder);
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

    folderEntries.sort((a, b) {
      final byStatus = a.status.index.compareTo(b.status.index);
      return byStatus != 0 ? byStatus : a.path.compareTo(b.path);
    });
    entries.addAll(folderEntries);
    summaries.add(_summary(folder, folderEntries));
  }

  entries.sort((a, b) {
    final byFolder = a.folderName.compareTo(b.folderName);
    if (byFolder != 0) return byFolder;
    final byStatus = a.status.index.compareTo(b.status.index);
    return byStatus != 0 ? byStatus : a.path.compareTo(b.path);
  });

  return UnsyncedOverview(
    entries: entries,
    folders: summaries,
    notices: notices,
    inspectedAt: DateTime.now(),
    truncated: truncated,
  );
}

UnsyncedFolderSummary _summary(
    SyncFolderConfig folder, List<UnsyncedEntry> entries) {
  final counts = <UnsyncedStatus, int>{};
  for (final entry in entries) {
    counts[entry.status] = (counts[entry.status] ?? 0) + 1;
  }
  return UnsyncedFolderSummary(folder.id, folder.name, counts);
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
