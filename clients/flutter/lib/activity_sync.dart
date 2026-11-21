import 'activity_log.dart';
import 'sync_controller.dart';

/// How many named transfer rows one finished run may add per direction.
///
/// A run can move thousands of files; the feed names this many and summarises
/// the rest in one row, so one busy sync cannot push everything else out of the
/// bounded local log.
const int activityTransferRowLimit = 40;

/// Maps one finished sync run into device-local activity rows.
///
/// Called once per completed run from the sync controller. Completed transfers
/// the native layer reported are recorded one row per file (local name, folder
/// and size); counts the client did not observe, or the part beyond
/// [activityTransferRowLimit], collapse into a single summary row. Failures and
/// conflicts keep their own rows. Only relative local names, folder names and
/// short reasons are recorded; nothing here is sent to the backend or logged.
void recordSyncRunActivity(
  ActivityLog log,
  SyncFolderConfig folder,
  Map<String, dynamic>? report,
) {
  final failed = <String>[];
  final errors = report?['errors'];
  if (errors is List) {
    for (final row in errors) {
      if (row is List && row.isNotEmpty) {
        failed.add(row.last.toString());
      } else {
        failed.add(row.toString());
      }
    }
  }
  final error = folder.lastError;
  final hasError = (error != null && error.isNotEmpty);
  if (report == null || failed.isNotEmpty || hasError) {
    log.record(
      kind: ActivityKind.failed,
      folder: folder.name,
      folderRootId: folder.remoteRootId,
      subject: failed.length > 1 ? '${failed.length} items' : 'sync',
      reason: _shortReason(hasError ? error : failed.first),
    );
  }
  if (report == null) return;
  if (folder.conflicts > 0) {
    log.record(
      kind: ActivityKind.conflict,
      folder: folder.name,
      folderRootId: folder.remoteRootId,
      subject: _count(folder.conflicts),
      reason: 'Choose which copy to keep in the Not synced screen.',
    );
  }
  _recordTransfers(
    log,
    folder,
    folder.completedTransfers.where((transfer) => transfer.isUpload),
    ActivityKind.uploaded,
    folder.uploaded,
  );
  _recordTransfers(
    log,
    folder,
    folder.completedTransfers.where((transfer) => !transfer.isUpload),
    ActivityKind.downloaded,
    folder.downloaded,
  );
}

/// Records one row per named transfer, then one row for the rest.
///
/// [reported] is the count the engine reported for this direction, so a run
/// whose events the client never observed (or that exceeded its own bound)
/// still records an honest total. With no named rows the wording stays the
/// plain count.
void _recordTransfers(
  ActivityLog log,
  SyncFolderConfig folder,
  Iterable<SyncTransfer> transfers,
  ActivityKind kind,
  int reported,
) {
  var named = 0;
  final seen = <String>{};
  for (final transfer in transfers) {
    if (named >= activityTransferRowLimit) break;
    if (!seen.add(transfer.path)) continue;
    log.record(
      kind: kind,
      folder: folder.name,
      folderRootId: folder.remoteRootId,
      subject: _subject(transfer.path),
      size: transfer.size,
    );
    named++;
  }
  final remaining = reported - named;
  if (named == 0) {
    if (reported > 0) {
      log.record(
        kind: kind,
        folder: folder.name,
        folderRootId: folder.remoteRootId,
        subject: _count(reported),
      );
    }
    return;
  }
  if (remaining > 0) {
    log.record(
      kind: kind,
      folder: folder.name,
      folderRootId: folder.remoteRootId,
      subject: remaining == 1 ? '1 more item' : '$remaining more items',
    );
  }
}

String _count(int value) => value == 1 ? '1 item' : '$value items';

/// The file name of a relative path, for example `budget.pdf`.
///
/// Only the last component is shown; the row already names its folder, and the
/// full relative path never leaves the device either way.
String _subject(String path) {
  final normalised = path.replaceAll('\\', '/');
  final trimmed = normalised.endsWith('/')
      ? normalised.substring(0, normalised.length - 1)
      : normalised;
  final cut = trimmed.lastIndexOf('/');
  final name = cut >= 0 ? trimmed.substring(cut + 1) : trimmed;
  if (name.isEmpty) return path;
  return name.length <= 200 ? name : '${name.substring(0, 200)}…';
}

/// One line, bounded, and never a full native diagnostic dump.
String _shortReason(String? text, {int max = 160}) {
  if (text == null) return 'Sync failed.';
  final firstLine = text.split('\n').first.trim();
  final cleaned = firstLine.replaceAll(RegExp(r'\s+'), ' ');
  if (cleaned.isEmpty) return 'Sync failed.';
  return cleaned.length <= max ? cleaned : '${cleaned.substring(0, max)}…';
}
