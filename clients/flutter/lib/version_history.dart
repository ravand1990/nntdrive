import 'package:flutter/material.dart';

import 'api.dart';

/// Versions the backend lists for one file; the history is capped server-side.
const int versionHistoryPageLimit = 200;

/// A byte count in the largest binary unit that fits, matching the browser's
/// own size labels.
String formatVersionSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 10 ? 0 : 1)} ${units[unit]}';
}

/// One version's timestamp in local time, or the raw value if it cannot be read.
String formatVersionTime(String createdAt) {
  final parsed = DateTime.tryParse(createdAt);
  if (parsed == null) return createdAt;
  final local = parsed.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

/// One file's version history: what content existed when, and how to go back.
///
/// The dialog owns no API client and no crypto. It receives the sealed-name
/// title already decrypted by the caller, reads the history through [load], and
/// restores through [restore], where the server re-checks that the revision
/// belongs to this file and account. Restoring copies nothing back into the
/// upload path: the earlier revision already exists, so only the current
/// pointer moves and the history keeps every version.
class VersionHistoryDialog extends StatefulWidget {
  const VersionHistoryDialog({
    super.key,
    required this.title,
    required this.currentVersion,
    required this.load,
    this.restore,
    this.download,
  });

  /// Decrypted file name, shown as the dialog heading only.
  final String title;

  /// The revision the file points at now, so the newest row is marked current.
  final String? currentVersion;

  final Future<List<VersionInfo>> Function() load;

  /// Restores one version. When null, no restore is offered at all.
  final Future<void> Function(VersionInfo version)? restore;

  /// Saves one version under a different name. When null, no download control.
  final void Function(VersionInfo version)? download;

  @override
  State<VersionHistoryDialog> createState() => _VersionHistoryDialogState();
}

class _VersionHistoryDialogState extends State<VersionHistoryDialog> {
  List<VersionInfo> _versions = [];
  bool _loading = true;
  String? _loadError;
  String? _current;
  String? _restoring;
  String? _notice;
  String? _actionError;

  @override
  void initState() {
    super.initState();
    _current = widget.currentVersion;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final versions = await widget.load();
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = 'The version history could not be read: $e';
      });
    }
  }

  Future<void> _confirmRestore(VersionInfo version) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore an earlier version?'),
        content: Text(
          'The file goes back to the content it had on '
          '${formatVersionTime(version.createdAt)}. The version that is '
          'current now stays in this list, so nothing is lost and you can '
          'switch back at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _restore(version);
  }

  Future<void> _restore(VersionInfo version) async {
    final restore = widget.restore;
    if (restore == null) return;
    setState(() {
      _restoring = version.revisionId;
      _actionError = null;
      _notice = null;
    });
    try {
      await restore(version);
      if (!mounted) return;
      setState(() {
        _restoring = null;
        _current = version.revisionId;
        _notice =
            'Restored the version from ${formatVersionTime(version.createdAt)}.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _restoring = null;
        _actionError = 'The version was not restored: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Version history — ${widget.title}'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_restoring != null) const LinearProgressIndicator(),
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(_notice!, style: theme.textTheme.bodyMedium),
              ),
            if (_actionError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _actionError!,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            Flexible(child: _body(theme)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
        ),
      );
    }
    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_loadError!),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _load,
              child: const Text('Try again'),
            ),
          ],
        ),
      );
    }
    if (_versions.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Text(
          'No versions yet. Uploading a new version of this file keeps the '
          'earlier content here, so it stays recoverable.',
          style: theme.textTheme.bodyMedium,
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      itemCount:
          _versions.length + (_versions.length >= versionHistoryPageLimit ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i == _versions.length) {
          // The server returns at most this many; older content still exists in
          // the per-file history but is not listed by this view.
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Only the newest $versionHistoryPageLimit versions are listed.',
              style: theme.textTheme.bodySmall,
            ),
          );
        }
        return _row(theme, _versions[i]);
      },
    );
  }

  Widget _row(ThemeData theme, VersionInfo version) {
    final isCurrent = version.revisionId == _current;
    final busy = _restoring != null;
    final canRestore = widget.restore != null && !isCurrent && !busy;
    final time = formatVersionTime(version.createdAt);
    return ListTile(
      key: ValueKey('version-row-${version.revisionId}'),
      leading: Icon(
        isCurrent ? Icons.check_circle : Icons.history,
        semanticLabel: isCurrent ? 'Current version' : 'Earlier version',
        color: isCurrent ? theme.colorScheme.primary : null,
      ),
      title: Text(isCurrent ? 'Current version' : time),
      subtitle: Text(
        isCurrent
            ? '${formatVersionSize(version.size)} · $time'
            : formatVersionSize(version.size),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.download != null)
            IconButton(
              key: ValueKey('version-download-${version.revisionId}'),
              icon: const Icon(Icons.download),
              tooltip: 'Download this version',
              onPressed: busy ? null : () => widget.download!(version),
            ),
          if (widget.restore != null && !isCurrent)
            TextButton(
              key: ValueKey('version-restore-${version.revisionId}'),
              onPressed: canRestore ? () => _confirmRestore(version) : null,
              child: const Text('Restore'),
            ),
        ],
      ),
    );
  }
}
