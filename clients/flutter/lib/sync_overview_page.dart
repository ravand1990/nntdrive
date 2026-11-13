import 'package:flutter/material.dart';

import 'sync_overview.dart';

/// Device-local overview: what is not fully synchronized and why.
///
/// Every row shows a text status (never colour alone) and a plain-language
/// reason. Actions are explicit: retry the folder or grant storage access.
class SyncOverviewPage extends StatefulWidget {
  const SyncOverviewPage({
    super.key,
    required this.load,
    required this.onSyncFolder,
    this.onGrantAccess,
  });

  final Future<UnsyncedOverview> Function() load;
  final Future<void> Function(String folderId) onSyncFolder;
  final Future<bool> Function(String folderId)? onGrantAccess;

  @override
  State<SyncOverviewPage> createState() => _SyncOverviewPageState();
}

class _SyncOverviewPageState extends State<SyncOverviewPage> {
  UnsyncedOverview? _overview;
  Object? _error;
  bool _loading = true;
  UnsyncedStatus? _status;
  String? _folderId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final overview = await widget.load();
      if (!mounted) return;
      setState(() {
        _overview = overview;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Not synced'),
        actions: [
          IconButton(
            tooltip: 'Check again',
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 32),
              const SizedBox(height: 12),
              const Text(
                'The sync status could not be checked. Nothing was changed.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              FilledButton(onPressed: _refresh, child: const Text('Try again')),
            ],
          ),
        ),
      );
    }
    final overview = _overview;
    if (overview == null) {
      return const SizedBox.shrink();
    }
    final entries = overview.filtered(status: _status, folderId: _folderId);
    final counts = overview.counts;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                overview.total == 0
                    ? 'Nothing is waiting for sync.'
                    : overview.total == 1
                        ? '1 item is not fully in sync.'
                        : '${overview.total} items are not fully in sync.',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final status in UnsyncedStatus.values)
                    if ((counts[status] ?? 0) > 0)
                      FilterChip(
                        label: Text('${status.label} (${counts[status]})'),
                        selected: _status == status,
                        onSelected: (selected) => setState(
                            () => _status = selected ? status : null),
                      ),
                ],
              ),
              if (overview.folders.length > 1) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: _folderId,
                  decoration: const InputDecoration(
                    labelText: 'Folder',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('All folders')),
                    for (final folder in overview.folders)
                      DropdownMenuItem<String?>(
                          value: folder.folderId,
                          child: Text(
                              '${folder.folderName} (${folder.total})')),
                  ],
                  onChanged: (value) => setState(() => _folderId = value),
                ),
              ],
            ],
          ),
        ),
        for (final notice in overview.notices)
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            color: theme.colorScheme.surfaceContainerHighest,
            child: ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(notice.folderName),
              subtitle: Text(notice.message),
            ),
          ),
        if (overview.truncated)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
                'The list is limited. Sync and check again to see the remaining items.'),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: entries.isEmpty
              ? _emptyState(theme)
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) =>
                      _row(context, entries[index]),
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            'Checked on this device only. File names never leave it.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  Widget _emptyState(ThemeData theme) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline,
                  size: 32, color: theme.colorScheme.primary),
              const SizedBox(height: 12),
              const Text('Everything is in sync.', textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                'No cloud-only, local-only, pending, failed, conflict, skipped or blocked items were found in the folders checked.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );

  Widget _row(BuildContext context, UnsyncedEntry entry) {
    final theme = Theme.of(context);
    final size = entry.size == null ? null : _formatSize(entry.size!);
    return ListTile(
      leading: Icon(_icon(entry.status), semanticLabel: entry.status.label),
      title: Text(entry.displayName.isEmpty ? entry.folderName : entry.displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${entry.status.label} · ${entry.folderName}'
              '${entry.displayFolderPath.isEmpty ? '' : ' · ${entry.displayFolderPath}'}'),
          Text(entry.reason),
        ],
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (size != null)
            Text(size, style: theme.textTheme.bodySmall),
          if (entry.retryable)
            IconButton(
              tooltip: 'Sync ${entry.folderName} now',
              onPressed: () => widget.onSyncFolder(entry.folderId),
              icon: const Icon(Icons.sync),
            ),
        ],
      ),
      onTap: () => _showDetails(context, entry),
    );
  }

  Future<void> _showDetails(BuildContext context, UnsyncedEntry entry) async {
    final grant = widget.onGrantAccess;
    final canGrant =
        entry.status == UnsyncedStatus.blocked && grant != null;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(entry.displayName.isEmpty ? entry.folderName : entry.displayName,
                  style: Theme.of(sheet).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text('${entry.status.label} · ${entry.folderName}'),
              const SizedBox(height: 6),
              SelectableText(entry.path),
              if (entry.pathTo != null) ...[
                const SizedBox(height: 6),
                Text('Pending destination: ${entry.pathTo}'),
              ],
              const SizedBox(height: 6),
              Text(entry.reason),
              if (entry.lastAttempt != null) ...[
                const SizedBox(height: 6),
                Text('Last attempt: ${entry.lastAttempt}'),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (entry.retryable)
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(sheet);
                        widget.onSyncFolder(entry.folderId);
                      },
                      child: const Text('Sync now'),
                    ),
                  if (canGrant)
                    FilledButton(
                      onPressed: () {
                        Navigator.pop(sheet);
                        grant(entry.folderId);
                      },
                      child: const Text('Grant access'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(sheet),
                    child: const Text('Close'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _icon(UnsyncedStatus status) => switch (status) {
        UnsyncedStatus.cloudOnly => Icons.cloud_outlined,
        UnsyncedStatus.localOnly => Icons.smartphone_outlined,
        UnsyncedStatus.pending => Icons.schedule,
        UnsyncedStatus.failed => Icons.error_outline,
        UnsyncedStatus.conflict => Icons.call_split,
        UnsyncedStatus.skipped => Icons.block_outlined,
        UnsyncedStatus.blocked => Icons.lock_outline,
      };

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
