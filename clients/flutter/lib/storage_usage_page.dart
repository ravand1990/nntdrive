import 'package:flutter/material.dart';

import 'account_search.dart';
import 'storage_usage.dart';
import 'download_cache.dart';

class StorageUsagePage extends StatefulWidget {
  const StorageUsagePage({super.key, required this.index, this.readCacheUsage,
    this.clearUnpinnedCache});
  final AccountSearch index;

  /// Reads the already opened device cache; must not open/reconcile or clean it.
  /// Missing reader or a failed reading means unavailable, never zero bytes.
  final Future<MeasuredCacheUsage> Function()? readCacheUsage;
  /// Uses the opened cache's serial API; the owner rejects late session
  /// admission and drains admitted cleanup.
  final Future<CacheCleanup> Function()? clearUnpinnedCache;

  @override
  State<StorageUsagePage> createState() => _StorageUsagePageState();
}

class _StorageUsagePageState extends State<StorageUsagePage> {
  StorageUsage? _usage;
  MeasuredCacheUsage? _cacheUsage;
  bool _cacheFailed = false;
  bool _clearing = false;
  String? _cleanupReport;
  bool _busy = false;
  bool _failed = false;
  int? _revision;
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
    widget.index.addListener(_changed);
    _refresh();
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (widget.index.closed) {
        _usage = null;
        _cacheUsage = null;
        _revision = null;
        _cleanupReport = null;
      }
    });
  }

  Future<void> _read() async {
    final revision = widget.index.snapshotRevision;
    final usage = await widget.index.readSnapshot(runStorageUsage);
    if (!mounted || widget.index.closed) return;
    setState(() {
      _usage = usage;
      _revision = revision;
    });
  }

  Future<void> _refresh() async {
    if (_busy || _clearing || widget.index.closed) return;
    setState(() => _busy = true);
    try {
      // Local accounting must still finish when account listing is offline.
      await Future.wait([_refreshAccount(), _refreshCache()]);
    } finally {
      if (mounted) setState(() => _busy = false);
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
    if (_busy || _clearing || widget.index.closed ||
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
    try {
      // An offline entry can still display the last complete session snapshot.
      if (_usage == null && widget.index.ready) await _read();
      if (!mounted || widget.index.closed) return;
      await widget.index.rebuild();
      if (!mounted || widget.index.closed) return;
      await _read();
      if (mounted) setState(() => _failed = false);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    widget.index.removeListener(_changed);
    _usage = null;
    _cacheUsage = null;
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
            onPressed: _busy || _clearing || widget.index.closed ? null : _refresh,
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
            'Sync-folder data is not measured. Refresh after cache or pin changes.',
          ),
          if (_busy) const Text('Refreshing device cache…'),
          if (widget.clearUnpinnedCache != null)
            OutlinedButton(
              onPressed: _busy || _clearing || widget.index.closed ||
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
            'Read-only account snapshot. Open this page or refresh after '
            'upload, delete or sync. Not continuously updated.',
          ),
          const SizedBox(height: 12),
          if (_busy) ...[
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
            'No duplicate detection or account/sync-folder cleanup actions.',
          ),
        ],
      ),
    );
  }

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
