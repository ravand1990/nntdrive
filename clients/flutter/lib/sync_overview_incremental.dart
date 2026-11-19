part of 'sync_overview.dart';

/// A persistent chunk list: publishing another page copies chunk references,
/// never the accumulated rows. Indexed ListView access is logarithmic in pages.
class _OverviewChunks extends ListBase<UnsyncedEntry> {
  _OverviewChunks(this.chunks, this.ends);
  final List<List<UnsyncedEntry>> chunks;
  final List<int> ends;
  @override
  int get length => ends.isEmpty ? 0 : ends.last;
  @override
  set length(int value) => throw UnsupportedError('immutable');
  @override
  void operator []=(int index, UnsyncedEntry value) =>
      throw UnsupportedError('immutable');
  @override
  UnsyncedEntry operator [](int index) {
    RangeError.checkValidIndex(index, this);
    var low = 0;
    var high = ends.length - 1;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (index < ends[mid]) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    return chunks[low][index - (low == 0 ? 0 : ends[low - 1])];
  }
}

List<UnsyncedEntry> _appendRows(
  List<UnsyncedEntry> previous,
  List<UnsyncedEntry> next,
) {
  if (next.isEmpty) return previous;
  if (previous.isEmpty) return next;
  final chunks = previous is _OverviewChunks ? previous.chunks : [previous];
  final ends = previous is _OverviewChunks ? previous.ends : [previous.length];
  return _OverviewChunks(
    List.unmodifiable([...chunks, next]),
    List.unmodifiable([...ends, previous.length + next.length]),
  );
}

Map<K, List<UnsyncedEntry>> _appendGroups<K>(
  Map<K, List<UnsyncedEntry>> previous,
  Map<K, List<UnsyncedEntry>> next,
) => Map.unmodifiable({
  ...previous,
  for (final entry in next.entries)
    entry.key: _appendRows(previous[entry.key] ?? const [], entry.value),
});

OverviewEntryProjection _appendProjection(
  OverviewEntryProjection previous,
  OverviewEntryProjection next,
) => OverviewEntryProjection._(
  _appendRows(previous.entries, next.entries),
  Map.unmodifiable({
    ...previous.counts,
    for (final entry in next.counts.entries)
      entry.key: (previous.counts[entry.key] ?? 0) + entry.value,
  }),
  _appendGroups(previous._byStatus, next._byStatus),
  _appendGroups(previous._byFolder, next._byFolder),
  _appendGroups(previous._byFolderStatus, next._byFolderStatus),
);

Future<Map<String, String>> _overviewErrorIndex(Map<String, dynamic>? report) =>
    Isolate.run(() {
      final result = <String, String>{};
      final errors = report?['item_errors'];
      if (errors is List) {
        for (final error in errors) {
          if (error is! Map || error['paths'] is! List) continue;
          final code = error['code'];
          final reason = _errorReason(code is String ? code : null);
          for (final path in error['paths'] as List) {
            if (path is String) result[path] = reason;
          }
        }
      }
      return Map<String, String>.unmodifiable(result);
    });

typedef FolderPageInspector =
    Future<void> Function(
      SyncFolderConfig folder,
      Future<void> Function(Map<String, dynamic>) onPage,
      bool Function() shouldContinue,
    );

/// Production result loading. Native comparison completes before the first
/// page, then each bounded batch is mapped/ordered/projected once. Pages are
/// appended in stable comparison order (ordered within each batch), not globally
/// re-sorted after every publication. All rows remain reachable without a cap.
Future<UnsyncedOverview> buildIncrementalUnsyncedOverview({
  required List<SyncFolderConfig> folders,
  required FolderPageInspector inspectPages,
  required OverviewCancellation cancellation,
  OverviewFolderMapper mapFolder = mapUnsyncedFolder,
  OverviewEntryOrderer orderEntries = orderUnsyncedEntries,
  OverviewEntryProjector projectEntries = projectUnsyncedEntries,
}) async {
  cancellation.check();
  final frozen = [for (final folder in folders) _freezeOverviewFolder(folder)];
  final sources = List<SyncFolderConfig>.of(folders);
  var projection = _projectUnsyncedEntries(const []);
  final summaries = <String, UnsyncedFolderSummary>{};
  final notices = <UnsyncedNotice>[];
  final noticeKeys = <(String, String)>{};
  var truncated = false;
  UnsyncedOverview snapshot(bool complete) => UnsyncedOverview._prepared(
    projection: projection,
    folders: summaries.values.toList(),
    notices: notices,
    inspectedAt: DateTime.now(),
    truncated: truncated,
    complete: complete,
  );

  Future<void> append(
    OverviewFolderInput folder,
    Map<String, dynamic> plan, {
    bool failed = false,
  }) async {
    final mapped = await _overviewStage(
      cancellation,
      () => mapFolder(folder, plan, 256, failed),
    );
    final ordered = await _overviewStage(
      cancellation,
      () => orderEntries(mapped.entries),
    );
    final prepared = await _overviewStage(
      cancellation,
      () => projectEntries(ordered),
    );
    projection = _appendProjection(projection, prepared);
    final old = summaries[folder.id]?.counts ?? const <UnsyncedStatus, int>{};
    summaries[folder.id] = UnsyncedFolderSummary(folder.id, folder.name, {
      ...old,
      for (final e in mapped.summary.counts.entries)
        e.key: (old[e.key] ?? 0) + e.value,
    });
    for (final notice in mapped.notices) {
      if (noticeKeys.add((folder.id, notice.message))) {
        notices.add(notice);
      }
    }
    truncated = truncated || mapped.truncated;
    cancellation.publish(snapshot(false));
  }

  for (var i = 0; i < frozen.length; i++) {
    cancellation.check();
    var folder = frozen[i];
    if (!folder.running && sources[i].running) {
      folder = _withActiveProgress(folder, sources[i].progress);
    }
    final errors = folder.running
        ? const <String, String>{}
        : await _overviewStage(
            cancellation,
            () => _overviewErrorIndex(folder.lastReport),
          );
    OverviewFolderInput input(
      List<String> excluded, [
      Map<String, String> relevant = const {},
    ]) => OverviewFolderInput(
      folder.id,
      folder.name,
      folder.lastSync,
      folder.storageAccessRequired,
      excluded,
      null,
      running: folder.running,
      errorReasons: relevant,
      progressPath: folder.progressPath,
      progressDirection: folder.progressDirection,
      progressComplete: folder.progressComplete,
    );
    if (folder.running || folder.storageAccessRequired) {
      await append(input(const []), const {});
      continue;
    }
    var first = true;
    var terminal = false;
    try {
      await _overviewStage(
        cancellation,
        () => inspectPages(sources[i], (page) async {
          cancellation.check();
          if (terminal) throw StateError('Unexpected overview page');
          // Preserve the legacy post-inspection activity recheck. If sync
          // started during permission/journal/comparison admission, expose its
          // current transfer/root once and close the now-redundant cursor.
          if (first && sources[i].running) {
            folder = _withActiveProgress(folder, sources[i].progress);
          }
          final blocked =
              _filesystemBlockReason(page['filesystem_blocked']) != null;
          final active = folder.running || page['sync_running'] == true;
          // Exclusions belong to configuration, not every native page. They are
          // omitted entirely for blocked/active roots, preserving root precedence.
          if (first && !blocked && !active) {
            for (var start = 0; start < folder.excluded.length; start += 256) {
              final end = start + 256 < folder.excluded.length
                  ? start + 256
                  : folder.excluded.length;
              await append(
                input(folder.excluded.sublist(start, end)),
                const {},
              );
            }
          }
          first = false;
          // Reject an incompatible/unbounded producer rather than silently cap.
          var records = 0;
          for (final field in ['items', 'skipped', 'case_collisions']) {
            final rows = page[field];
            if (rows is List) records += rows.length;
          }
          if (records > 256) throw StateError('Unbounded overview page');
          final relevant = <String, String>{};
          final items = page['items'];
          if (items is List) {
            for (final item in items) {
              if (item is! Map) continue;
              for (final field in ['path', 'path_to']) {
                final path = item[field];
                if (path is String && errors.containsKey(path)) {
                  relevant[path] = errors[path]!;
                }
              }
            }
          }
          await append(input(const [], relevant), page);
          terminal = page['done'] == true || blocked || active;
        }, () => !cancellation.isCancelled && !terminal),
      );
      cancellation.check();
      if (!terminal) throw StateError('Incomplete overview comparison');
    } on OverviewCancelled {
      rethrow;
    } catch (_) {
      cancellation.check();
      // Already published pages remain explicitly partial if loading failed.
      // Never turn a missing tail into an empty successful comparison.
      truncated = true;
      if (first) {
        for (var start = 0; start < folder.excluded.length; start += 256) {
          final end = start + 256 < folder.excluded.length
              ? start + 256
              : folder.excluded.length;
          await append(
            input(folder.excluded.sublist(start, end)),
            const {},
            failed: true,
          );
        }
      }
      await append(input(const []), const {}, failed: true);
    }
  }
  cancellation.check();
  final result = snapshot(true);
  cancellation.publish(result);
  return result;
}
