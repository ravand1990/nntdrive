import 'dart:async';

import 'package:flutter/material.dart';

import 'sync_controller.dart' show originalConflictPath;
import 'sync_overview.dart';
import 'sync_widgets.dart' show ConflictChoiceDialog;

/// Applies one conflict choice to a discovered conflict copy.
typedef ResolveConflictCallback = Future<void> Function(
    String folderId, String copyPath, String choice);

/// Device-local overview: what is not fully synchronized and why.
///
/// Every row shows a text status (never colour alone) and a plain-language
/// reason. Actions are explicit: retry the folder, resolve a conflict or grant
/// storage access, and the list reloads afterwards so nobody has to guess
/// whether the action changed anything.
class SyncOverviewPage extends StatefulWidget {
  const SyncOverviewPage({
    super.key,
    required this.load,
    required this.onSyncFolder,
    this.onGrantAccess,
    this.onResolveConflict,
    this.canRevealLocal,
    this.onRevealLocal,
    this.watch,
    this.isBusy,
  });

  final Future<UnsyncedOverview> Function(OverviewCancellation cancellation) load;
  final Future<void> Function(String folderId) onSyncFolder;
  final Future<bool> Function(String folderId)? onGrantAccess;

  /// Resolves one conflict copy; when absent the view offers no conflict action.
  final ResolveConflictCallback? onResolveConflict;

  /// Desktop only. Presence is checked when opening details and again on tap.
  final Future<bool> Function(UnsyncedEntry)? canRevealLocal;
  final Future<void> Function(UnsyncedEntry)? onRevealLocal;

  /// Notifies while sync state changes, so a finished round refreshes the list.
  final Listenable? watch;

  /// Whether sync is still working; while true a notification does not reload.
  final bool Function()? isBusy;

  @override
  State<SyncOverviewPage> createState() => _SyncOverviewPageState();
}

class _SyncOverviewPageState extends State<SyncOverviewPage> {
  static const _refreshDelay = Duration(milliseconds: 300);

  UnsyncedOverview? _overview;
  Object? _error;
  bool _loading = true;
  UnsyncedStatus? _status;
  String? _folderId;

  /// Row or folder whose action is running, so its buttons cannot repeat it.
  String? _acting;

  /// Debounces sync notifications into one reload.
  Timer? _refreshTimer;

  /// Admit one inspection at a time and retain at most one follow-up request.
  bool _refreshRunning = false;
  bool _refreshQueued = false;
  bool _explicitRefreshQueued = false;
  OverviewCancellation? _refreshCancellation;

  bool get _canDrainRefresh => _refreshQueued &&
      (_explicitRefreshQueued ||
          (_acting == null && !(widget.isBusy?.call() ?? false)));

  @override
  void initState() {
    super.initState();
    widget.watch?.addListener(_onSyncChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(SyncOverviewPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.watch != widget.watch) {
      oldWidget.watch?.removeListener(_onSyncChanged);
      widget.watch?.addListener(_onSyncChanged);
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _refreshCancellation?.cancel();
    widget.watch?.removeListener(_onSyncChanged);
    super.dispose();
  }

  /// A sync round that finished while this page is open reloads the plan.
  void _onSyncChanged() {
    if (_acting != null || (widget.isBusy?.call() ?? false)) return;
    if (_refreshRunning) {
      _refreshQueued = true;
      return;
    }
    if (_refreshTimer?.isActive ?? false) return;
    _refreshTimer = Timer(_refreshDelay, () {
      _refreshTimer = null;
      if (!mounted || _acting != null || (widget.isBusy?.call() ?? false)) return;
      _refresh(showSpinner: false);
    });
  }

  Future<void> _refresh({bool showSpinner = true}) async {
    if (!mounted) return;
    // An explicit refresh also satisfies any still-debouncing notification.
    _refreshTimer?.cancel();
    _refreshTimer = null;
    if (_refreshRunning) {
      _refreshQueued = true;
      _explicitRefreshQueued = true;
      return;
    }
    _refreshRunning = true;
    final cancellation = OverviewCancellation();
    _refreshCancellation = cancellation;
    setState(() {
      if (showSpinner || _overview == null) _loading = true;
      _error = null;
    });
    try {
      do {
        _refreshQueued = false;
        _explicitRefreshQueued = false;
        try {
          final overview = await widget.load(cancellation);
          if (!mounted) return;
          // A change during inspection needs a fresh plan, not this old result.
          if (_canDrainRefresh) continue;
          setState(() {
            _overview = overview;
            _loading = false;
          });
        } catch (e) {
          if (!mounted) return;
          if (_canDrainRefresh) continue;
          setState(() {
            _error = e;
            _loading = false;
          });
        }
      } while (_canDrainRefresh);
    } finally {
      // Busy/action admission is retried by the next idle notification or by
      // _runAction's mandatory completion refresh, never by a polling loop.
      _refreshRunning = false;
      _refreshCancellation = null;
      _refreshQueued = false;
      _explicitRefreshQueued = false;
    }
  }

  /// Runs one row action, reports a failure, and always reloads the plan.
  Future<void> _runAction(String key, Future<void> Function() action,
      {String? done}) async {
    if (_acting != null) return;
    setState(() => _acting = key);
    try {
      await action();
      if (!mounted) return;
      if (done != null) _toast(done);
    } catch (_) {
      if (!mounted) return;
      _toast('That action did not finish. Try again.');
    } finally {
      if (mounted) {
        setState(() => _acting = null);
        await _refresh(showSpinner: false);
      }
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _keyFor(UnsyncedEntry entry) => '${entry.folderId}\u0000${entry.path}';


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
            _acting == _keyFor(entry)
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    tooltip: 'Sync ${entry.folderName} now',
                    onPressed: _acting != null ? null : () => _syncFolder(entry),
                    icon: const Icon(Icons.sync),
                  ),
        ],
      ),
      onTap: () => _showDetails(context, entry),
    );
  }

  Future<void> _showDetails(BuildContext context, UnsyncedEntry entry) async {
    var canReveal = false;
    if (widget.onRevealLocal != null && widget.canRevealLocal != null) {
      try {
        canReveal = await widget.canRevealLocal!(entry);
      } catch (_) {
        // Missing, removed or unreadable paths never enable a launch.
      }
      if (!context.mounted) return;
    }
    final grant = widget.onGrantAccess;
    final canGrant =
        entry.status == UnsyncedStatus.blocked && grant != null;
    final canResolve = entry.status == UnsyncedStatus.conflict &&
        widget.onResolveConflict != null;
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
              if (widget.onRevealLocal != null && !canReveal)
                const Text('No safe local copy is available. Refresh after syncing.'),
              Wrap(
                spacing: 8,
                children: [
                  if (entry.retryable)
                    FilledButton(
                      onPressed: _acting != null
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _syncFolder(entry);
                            },
                      child: const Text('Sync now'),
                    ),
                  if (canResolve)
                    FilledButton(
                      onPressed: _acting != null
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _resolveConflict(entry);
                            },
                      child: const Text('Resolve conflict'),
                    ),
                  if (canGrant)
                    FilledButton(
                      onPressed: _acting != null
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _grantAccess(entry);
                            },
                      child: const Text('Grant access'),
                    ),
                  if (widget.onRevealLocal != null)
                    OutlinedButton.icon(
                      onPressed: !canReveal || _acting != null
                          ? null
                          : () {
                              Navigator.pop(sheet);
                              _runAction(_keyFor(entry),
                                  () => widget.onRevealLocal!(entry));
                            },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Show local copy'),
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

  Future<void> _syncFolder(UnsyncedEntry entry) => _runAction(
        _keyFor(entry),
        () => widget.onSyncFolder(entry.folderId),
        done: 'Sync finished. The list was refreshed.',
      );

  Future<void> _grantAccess(UnsyncedEntry entry) {
    final grant = widget.onGrantAccess;
    if (grant == null) return Future<void>.value();
    return _runAction(
      _keyFor(entry),
      () async {
        final granted = await grant(entry.folderId);
        if (!granted) throw StateError('Storage access was not granted');
      },
      done: 'Storage access is granted. Sync this folder again.',
    );
  }

  Future<void> _resolveConflict(UnsyncedEntry entry) async {
    final resolve = widget.onResolveConflict;
    if (resolve == null) return;
    final original = originalConflictPath(entry.path) ?? entry.path;
    final choice = await showDialog<String>(
      context: context,
      builder: (_) =>
          ConflictChoiceDialog(original: original, copy: entry.path),
    );
    if (choice == null || !mounted) return;
    await _runAction(
      _keyFor(entry),
      () => resolve(entry.folderId, entry.path, choice),
      done: 'Conflict resolved. Both versions stay recoverable.',
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
