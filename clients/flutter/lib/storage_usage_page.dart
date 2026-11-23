import 'package:flutter/material.dart';

import 'account_search.dart';
import 'storage_usage.dart';

class StorageUsagePage extends StatefulWidget {
  const StorageUsagePage({super.key, required this.index});
  final AccountSearch index;

  @override
  State<StorageUsagePage> createState() => _StorageUsagePageState();
}

class _StorageUsagePageState extends State<StorageUsagePage> {
  StorageUsage? _usage;
  bool _busy = false;
  bool _failed = false;
  int? _revision;

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
        _revision = null;
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
    if (_busy || widget.index.closed) return;
    setState(() => _busy = true);
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    widget.index.removeListener(_changed);
    _usage = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final usage = _usage;
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
            onPressed: _busy || widget.index.closed ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
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
            const SizedBox(height: 16),
            Text(
              'Largest files (up to 20)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (usage.largest.isEmpty) const Text('No live files.'),
            for (final file in usage.largest)
              ListTile(
                title: Text(file.path),
                subtitle: Text('${file.bytes} bytes'),
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
                subtitle: Text(
                  '${file.bytes} bytes · ${file.updatedAt.toIso8601String()} (UTC)',
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
            'No duplicate detection or cleanup actions.',
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
