import 'package:flutter/material.dart';

import 'account_search.dart';
import 'cache_duplicates.dart';
import 'storage_usage.dart';
import 'download_cache.dart';
import 'sync_disk_usage.dart';

class StorageUsagePage extends StatefulWidget {
  const StorageUsagePage({super.key, required this.index, this.readCacheUsage,
    this.clearUnpinnedCache, this.readSyncUsage, this.reviewCacheDuplicates,
    this.aggregate = runStorageUsage});
  /// Production remains the top-level worker; injection permits lifecycle gates.
  final Future<StorageUsage> Function(Map<String, SearchEntry>) aggregate;
  /// Session/controller-owned read-only worker. No journal or permission prompt.
  final Future<SyncDiskUsage> Function()? readSyncUsage;
  final AccountSearch index;

  /// Reads the already opened device cache; must not open/reconcile or clean it.
  /// Missing reader or a failed reading means unavailable, never zero bytes.
  final Future<MeasuredCacheUsage> Function()? readCacheUsage;
  /// Uses the opened cache's serial API; the owner rejects late session
  /// admission and drains admitted cleanup.
  final Future<CacheCleanup> Function()? clearUnpinnedCache;
  /// Explicit only; owner admits/drains the already opened cache worker.
  final Future<CacheDuplicateReview> Function()? reviewCacheDuplicates;

  @override
  State<StorageUsagePage> createState() => _StorageUsagePageState();
}

class _StorageUsagePageState extends State<StorageUsagePage> {
  StorageUsage? _usage;
  SyncDiskUsage? _syncUsage;
  bool _syncFailed = false;
  MeasuredCacheUsage? _cacheUsage;
  bool _cacheFailed = false;
  bool _clearing = false;
  bool _reviewing = false;
  bool _reviewFailed = false;
  CacheDuplicateReview? _duplicates;

  Future<void> _reviewDuplicates() async {
    final reader = widget.reviewCacheDuplicates;
    if (!mounted || _busy || _clearing || _reviewing || widget.index.closed || reader == null) return;
    setState(() { _reviewing = true; _reviewFailed = false; _duplicates = null; });
    try {
      final result = await reader();
      if (!mounted || widget.index.closed) return;
      setState(() => _duplicates = result);
    } catch (_) {
      if (mounted && !widget.index.closed) setState(() => _reviewFailed = true);
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }
  String? _cleanupReport;
  bool _busy = false;
  bool _failed = false;
  int? _revision;
  late int _observedRevision;
  bool _refreshingAccount = false;
  Future<void>? _reading;
  bool _opening = false;
  String? _navigationError;

  Future<void> _openContainingFolder(StorageFile file) async {
    final revision = _revision;
    if (_opening || _busy || widget.index.closed || revision == null ||
        revision != widget.index.snapshotRevision) { return; }
    setState(() { _opening = true; _navigationError = null; });
    try {
      final entry = await widget.index.readSnapshot((snapshot) async {
        if (revision != widget.index.snapshotRevision) throw const SearchUnavailable();
        final entry = snapshot[file.id];
        if (entry == null || entry.file.isDir) throw const SearchUnavailable();
        return entry;
      });
      if (!mounted || widget.index.closed || revision != widget.index.snapshotRevision) return;
      Navigator.pop(context, entry);
    } catch (_) {
      if (mounted && !widget.index.closed) {
        setState(() => _navigationError =
          'Folder unavailable. Refresh storage usage and retry.');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Widget _folderAction(StorageFile file) => TextButton(
    onPressed: _busy || _opening || widget.index.closed ||
        _revision != widget.index.snapshotRevision ? null : () => _openContainingFolder(file),
    child: const Text('Open containing folder'),
  );

  @override
  void initState() {
    super.initState();
    _observedRevision = widget.index.snapshotRevision;
    widget.index.addListener(_changed);
    _refresh();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (widget.index.closed) {
        _usage = null;
        _cacheUsage = null;
        _syncUsage = null;
        _revision = null;
        _cleanupReport = null;
        _duplicates = null;
        _reviewFailed = false;
      }
    });
    final revision = widget.index.snapshotRevision;
    if (revision == _observedRevision) return;
    _observedRevision = revision;
    // Busy/history notifications do not admit work. A manual rebuild is read
    // by its owner below, not once here and again after rebuild completes.
    if (!widget.index.closed && !_refreshingAccount) _read();
  }

  Future<void> _read() {
    final active = _reading;
    if (active != null) return active;
    final reading = _readLatest().whenComplete(() {
      _reading = null;
      if (mounted) setState(() {});
    });
    _reading = reading;
    if (mounted) setState(() {});
    return reading;
  }

  Future<void> _readLatest() async {
    while (mounted && !widget.index.closed && widget.index.ready) {
      final revision = widget.index.snapshotRevision;
      try {
        final usage = await widget.index.readSnapshot(widget.aggregate);
        if (!mounted || widget.index.closed) return;
        if (revision != widget.index.snapshotRevision) continue;
        setState(() {
          _usage = usage;
          _revision = revision;
          _failed = false;
        });
      } catch (_) {
        if (!mounted || widget.index.closed) return;
        // readSnapshot rejects replacements too. Neither obsolete errors nor
        // obsolete results may replace the last complete summary.
        if (revision != widget.index.snapshotRevision) continue;
        setState(() => _failed = true);
      }
      return; // No polling/retry loop for a failed unchanged revision.
    }
  }

  Future<void> _refresh() async {
    if (_busy || _clearing || _reviewing || widget.index.closed) return;
    setState(() => _busy = true);
    try {
      // Local accounting must still finish when account listing is offline.
      await Future.wait([_refreshAccount(), _refreshCache(), _refreshSync()]);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshSync() async {
    try {
      final reader = widget.readSyncUsage;
      if (reader == null) throw StateError('Sync-folder accounting unavailable');
      final usage = await reader();
      if (!mounted || widget.index.closed) return;
      setState(() { _syncUsage = usage; _syncFailed = false; });
    } catch (_) {
      if (mounted && !widget.index.closed) {
        setState(() => _syncFailed = true);
      }
    }
  }

  Future<void> _refreshCache() async {
    try {
      final reader = widget.readCacheUsage;
      if (reader == null) throw StateError('Cache accounting unavailable');
      final usage = await reader();
      if (!mounted || widget.index.closed) return;
      setState(() {
        _cacheUsage = usage;
        _cacheFailed = false;
      });
    } catch (_) {
      if (mounted && !widget.index.closed) {
        setState(() => _cacheFailed = true);
      }
    }
  }

  Future<void> _clearUnpinned() async {
    if (_busy || _clearing || _reviewing || widget.index.closed ||
        widget.clearUnpinnedCache == null) {
      return;
    }
    // Include confirmation in single-flight admission.
    setState(() => _clearing = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear unpinned cache?'),
          content: const Text(
            'Delete currently unpinned indexed downloaded copies from this '
            'device only. Pinned copies, sync folders and account files stay. '
            'Opening removed copies again needs the network. Totals may have '
            'changed since measurement; pin flags are checked during cleanup.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Clear')),
          ],
        ),
      );
      if (confirmed != true || !mounted || widget.index.closed) return;
      setState(() {
        _cacheFailed = true;
        _cleanupReport = null;
        _duplicates = null;
        _reviewFailed = false;
      });
      try {
        final result = await widget.clearUnpinnedCache!();
        if (!mounted || widget.index.closed) return;
        setState(() => _cleanupReport =
          'Last cleanup: Removed ${result.removedEntries} cached copies and reclaimed '
          '${result.freedBytes} measured bytes. '
          '${result.keptPinnedEntries} pinned entries kept. '
          '${result.failedEntries} copies could not be removed.');
      } catch (_) {
        if (!mounted || widget.index.closed) return;
        setState(() => _cleanupReport =
          'Cache cleanup failed; some copies may already have been removed. '
          'Refresh totals before retrying.');
      }
      // Refresh after partial failure too, independently of account network.
      if (mounted && !widget.index.closed) await _refreshCache();
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  Future<void> _refreshAccount() async {
    _refreshingAccount = true;
    try {
      // Join any automatic reader before rebuilding; never overlap aggregates.
      await _reading;
      if (!mounted || widget.index.closed) return;
      // An offline entry can still display the last complete session snapshot.
      if (_usage == null && widget.index.ready) await _read();
      if (!mounted || widget.index.closed) return;
      await widget.index.rebuild();
      if (!mounted || widget.index.closed) return;
      await _read();
    } catch (_) {
      if (mounted && !widget.index.closed) setState(() => _failed = true);
    } finally {
      _refreshingAccount = false;
    }
  }

  @override
  void dispose() {
    widget.index.removeListener(_changed);
    _usage = null;
    _cacheUsage = null;
    _duplicates = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
    final cache = _cacheUsage;
    final stale =
        _failed ||
        widget.index.failed ||
        (_revision != null && _revision != widget.index.snapshotRevision);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage usage'),
        actions: [
          IconButton(
            tooltip: 'Refresh storage usage',
            onPressed: _busy || _clearing || _reviewing || widget.index.closed ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This device · indexed offline cache',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Measured file lengths, separate from logical account bytes. '
            'Pinned copies are part of the cache, not additional bytes. '
            'Counts are cached revisions, not unique account files. '
            'Sync-folder data is reported separately. Refresh after cache or pin changes.',
          ),
          if (_busy) const Text('Refreshing device cache…'),
          if (widget.clearUnpinnedCache != null)
            OutlinedButton(
              onPressed: _busy || _clearing || _reviewing || widget.index.closed ||
                  cache == null || _cacheFailed ? null : _clearUnpinned,
              child: Text(_clearing ? 'Cache cleanup pending…' : 'Clear unpinned cache'),
            ),
          if (_cleanupReport != null) Text(_cleanupReport!),
          if (_cacheFailed && !widget.index.closed)
            Text(cache == null
                ? 'Device cache usage unavailable. Refresh to retry.'
                : 'Device cache refresh failed. Previous cache totals may be stale. Refresh to retry.'),
          if (cache != null) ...[
            Text('Cache total: ${cache.bytes} bytes · ${cache.copies} copies'),
            Text('Pinned: ${cache.pinnedBytes} bytes · ${cache.pinnedCopies} copies'),
            Text('Unpinned: ${cache.unpinnedBytes} bytes · ${cache.unpinnedCopies} copies'),
            if (cache.excludedCopies > 0)
              Text('${cache.excludedCopies} indexed copies missing, inaccessible or not regular files; excluded from measured totals.'),
          ],
          const Text(
            'Only indexed regular cache files are measured; scratch, orphan and '
            'index files are excluded. Not allocated disk space, content integrity '
            'or a whole-directory total. Readings can change during measurement '
            'and are not continuously updated.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Live files · logical bytes',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Read-only account snapshot. Adopts published index revisions. '
            'Refresh after upload, delete or sync; mutations are not observed '
            'continuously.',
          ),
          const SizedBox(height: 12),
          if (_busy || (_reading != null && !widget.index.closed)) ...[
            const LinearProgressIndicator(),
            const Text('Refreshing account storage…'),
          ],
          if (widget.index.closed)
            const Text('Session closed. Unlock again to view storage.'),
          if (stale)
            Text(
              usage == null
                  ? 'Storage usage unavailable. Refresh to retry.'
                  : 'Refresh incomplete or snapshot changed. Previous totals may be stale. Refresh to retry.',
            ),
          if (usage != null) ...[
            SelectableText(
              'Total: ${usage.bytes} bytes · ${usage.files} files',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            _buckets('By top-level folder', usage.folders),
            _buckets('By filename extension', usage.types),
            const Text('Open containing folder navigates inside this app, not the device file manager. '
              'The folder is freshly listed and decrypted; stale or moved entries may require refresh.'),
            if (_navigationError != null) Text(_navigationError!),
            const SizedBox(height: 16),
            Text(
              'Largest files (up to 20)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (usage.largest.isEmpty) const Text('No live files.'),
            for (final file in usage.largest)
              ListTile(
                title: Text(file.path),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [Text('${file.bytes} bytes'), _folderAction(file)],
                ),
              ),
            const SizedBox(height: 16),
            Text(
              'Oldest large files (up to 20)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const Text(
              'Live files at least 10 MiB (10485760 bytes), oldest namespace '
              'modification date first. Dates shown in UTC; not access time or '
              'verified content age, and not a safe-delete recommendation.',
            ),
            Text(
              'Large files with unknown modification date: ${usage.unknownLargeDates}',
            ),
            if (usage.oldestLarge.isEmpty)
              const Text('No large live files with a known modification date.'),
            for (final file in usage.oldestLarge)
              ListTile(
                title: Text(file.path),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${file.bytes} bytes · ${file.updatedAt.toIso8601String()} (UTC)'),
                    _folderAction(file),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Counts include live files only, including zero-byte files; '
            'folder metadata is not counted as content. Sizes come from namespace '
            'listings, not downloaded content verification. No tolerance is applied '
            'within a complete snapshot, but concurrent changes during traversal '
            'can produce a mixed-time view. History, trash, quota, physical Usenet '
            'usage, local sync folders, cache and pins are not included. '
            'No account or sync-folder duplicate detection or cleanup actions.',
          ),
          const SizedBox(height: 16),
          const Text(
            'This device · sync-folder file lengths',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const Text(
            'Read-only measured regular-file lengths, per configured root in '
            'sync-settings order (up to 20 roots). Includes hidden, excluded and '
            'local-only files. Not journal equality or verified synced content. '
            'Not allocated disk space or deduplicated physical usage: hard links '
            'and separate copies can count repeatedly. Never added to cache or '
            'account totals; no combined device total.',
          ),
          if (_busy) const Text('Measuring sync folders…'),
          if (_syncFailed && !widget.index.closed)
            Text(_syncUsage == null
              ? 'Sync-folder usage unavailable. Refresh to retry.'
              : 'Sync-folder refresh failed. Previous observations may be stale. Refresh to retry.'),
          if (_syncUsage != null) ...[
            if (_syncUsage!.roots.isEmpty) const Text('No configured sync folders.'),
            for (final item in _syncUsage!.roots.indexed)
              Text('Sync root ${item.$1 + 1}: ${_syncObservation(item.$2)}'),
          ],
          const Text(
            'Overlapping or equal configured roots are not measured (both rows). '
            'Links are never followed; unsafe/missing roots are unavailable. '
            'Incomplete rows show observed bytes only, not totals. Shared budget: '
            '10000 entries and 2 seconds between filesystem operations; a stalled '
            'OS call can take longer. Readings are mixed-time, not atomic against '
            'local path swaps, and not continuously updated. Refresh to recheck. '
            'No sync-folder cleanup or duplicate detection.',
          ),
          const SizedBox(height: 16),
          const Text('Indexed downloaded revisions · exact duplicate review',
            style: TextStyle(fontWeight: FontWeight.bold)),
          const Text('Explicit read-only local review, not a complete account or '
            'sync-folder scan. SHA-256 selects candidates locally; byte comparison '
            'confirms displayed groups, including empty files. No names, hashes or '
            'content are uploaded or persisted by review. No deletion action, '
            'reclaimed-space estimate or safe-to-delete advice.'),
          if (widget.reviewCacheDuplicates != null)
            FilledButton.tonal(
              onPressed: _busy || _clearing || _reviewing || widget.index.closed
                ? null : _reviewDuplicates,
              child: Text(_reviewing ? 'Reviewing cached copies…' : 'Review exact cache duplicates'),
            )
          else const Text('Cache review unavailable.'),
          if (_reviewFailed) const Text('Cache review failed. Retry explicitly; no files were changed.'),
          if (_duplicates != null) ...[
            Text(_duplicates!.partial
              ? 'Partial review: coverage or displayed results are incomplete.'
              : 'Review completed within the indexed-copy scope.'),
            Text('${_duplicates!.examined} indexed revisions examined · '
              '${_duplicates!.excluded} unsafe, missing or changed copies excluded · '
              '${_duplicates!.bytesRead} content bytes read'),
            if (_duplicates!.groups.isEmpty)
              const Text('No exact groups confirmed in this observation; not proof that no duplicates exist.'),
            for (final item in _duplicates!.groups.indexed) ...[
              Text('Exact group ${item.$1 + 1} · ${item.$2.first.sizeBytes} bytes per copy'),
              for (final entry in item.$2)
                Text('File ${entry.fileId} · revision ${entry.revisionId}'
                  '${entry.pinned ? ' · pinned' : ''}'),
            ],
          ],
          const Text('Bounds: 1000 indexed revisions, 256 MiB total content reads '
            '(including comparison), 2 seconds between operations, 20 groups and '
            '100 displayed copies. OS calls can take longer. Opaque IDs identify '
            'cached revisions, not authenticated display names. Results are '
            'mixed-time observations, may already be stale and are not atomic '
            'against hostile filesystem swaps. Rerun explicitly after changes; '
            'ordinary refresh does not scan duplicate content.'),
        ],
      ),
    );
  }

  String _syncObservation(SyncDiskRootUsage usage) => switch (usage.state) {
    SyncDiskState.complete => '${usage.bytes} measured bytes · ${usage.files} regular files (complete observation)',
    SyncDiskState.incomplete => 'Incomplete: ${usage.bytes} observed bytes · ${usage.files} regular files · ${usage.skipped} unsafe/skipped entries (not a total)',
    SyncDiskState.unavailable => 'Unavailable: missing, unsafe or unreadable root/tree',
    SyncDiskState.overlap => 'Not measured: overlapping configured roots',
  };

  Widget _buckets(String title, List<StorageBucket> buckets) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      Text(title, style: Theme.of(context).textTheme.titleMedium),
      const Text('Top 20 groups by bytes; any remaining groups are combined.'),
      for (final bucket in buckets)
        ListTile(
          title: Text(bucket.label),
          subtitle: Text('${bucket.bytes} bytes · ${bucket.files} files'),
        ),
    ],
  );
}
