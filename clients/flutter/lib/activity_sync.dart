import 'activity_log.dart';
import 'sync_controller.dart';

/// Maps one finished sync run into device-local activity rows.
///
/// Called once per completed run from the sync controller, for failures and for
/// the upload/download/conflict counts the engine actually reported. Only
/// relative local names, folder names and short reasons are recorded; nothing
/// here is sent to the backend or written to logs.
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
  if (folder.uploaded > 0) {
    log.record(
      kind: ActivityKind.uploaded,
      folder: folder.name,
      folderRootId: folder.remoteRootId,
      subject: _count(folder.uploaded),
    );
  }
  if (folder.downloaded > 0) {
    log.record(
      kind: ActivityKind.downloaded,
      folder: folder.name,
      folderRootId: folder.remoteRootId,
      subject: _count(folder.downloaded),
    );
  }
}

String _count(int value) => value == 1 ? '1 item' : '$value items';

/// One line, bounded, and never a full native diagnostic dump.
String _shortReason(String? text, {int max = 160}) {
  if (text == null) return 'Sync failed.';
  final firstLine = text.split('\n').first.trim();
  final cleaned = firstLine.replaceAll(RegExp(r'\s+'), ' ');
  if (cleaned.isEmpty) return 'Sync failed.';
  return cleaned.length <= max ? cleaned : '${cleaned.substring(0, max)}…';
}
