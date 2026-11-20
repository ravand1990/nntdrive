import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'activity_log.dart';

/// Device-local activity feed and notification centre.
///
/// Everything shown here is decrypted locally; the page never sends anything to
/// the server and never writes names to logs.
class ActivityPage extends StatefulWidget {
  const ActivityPage({super.key, required this.log});

  final ActivityLog log;

  @override
  State<ActivityPage> createState() => _ActivityPageState();
}

class _ActivityPageState extends State<ActivityPage> {
  ActivityKind? _kind;
  String? _folder;
  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.log.addListener(_changed);
    unawaited(widget.log.load());
  }

  @override
  void dispose() {
    widget.log.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _export() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ActivityExportDialog(log: widget.log),
    );
  }

  Future<void> _settings() async {
    await showDialog<void>(
      context: context,
      builder: (_) => ActivitySettingsDialog(log: widget.log),
    );
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear activity?'),
        content: const Text(
          'This removes the history stored on this device. Files, sync folders '
          'and sync reports are not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await widget.log.clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final log = widget.log;
    final folders = log.folderCounts.keys.toList()..sort();
    // A folder that disappeared from the filter must not hide every row.
    final folder = _folder != null && folders.contains(_folder)
        ? _folder
        : null;
    final query = _search.text.trim();
    final entries = log.filtered(kind: _kind, folder: folder, query: query);
    final notifications = log.notifications;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Activity'),
        actions: [
          IconButton(
            onPressed: _settings,
            icon: const Icon(Icons.tune),
            tooltip: 'Activity settings',
          ),
          IconButton(
            onPressed: _export,
            icon: const Icon(Icons.ios_share),
            tooltip: 'Export activity report',
          ),
          IconButton(
            onPressed: _clear,
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: 'Clear activity history',
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (notifications.isNotEmpty)
              _NotificationSection(
                notifications: notifications,
                onDismiss: log.dismiss,
                onDismissAll: log.dismissAll,
              ),
            if (log.entries.isNotEmpty)
              _ActivitySearchField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                onClear: () {
                  _search.clear();
                  setState(() {});
                },
              ),
            if (folders.length > 1 || _kind != null)
              _FilterBar(
                kind: _kind,
                folder: folder,
                folders: folders,
                onKind: (value) => setState(() => _kind = value),
                onFolder: (value) => setState(() => _folder = value),
              ),
            Expanded(
              child: entries.isEmpty
                  ? _EmptyActivity(
                      filtered:
                          _kind != null || folder != null || query.isNotEmpty,
                      searching: query.isNotEmpty,
                      hasHistory: log.entries.isNotEmpty,
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: entries.length,
                      itemBuilder: (context, index) => ActivityRow(
                        entry: entries[index],
                        onDismiss:
                            entries[index].isNotification &&
                                !log.dismissedIds.contains(entries[index].id)
                            ? () => log.dismiss(entries[index].id)
                            : null,
                      ),
                    ),
            ),
            if (log.entries.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  'Stored only on this device. Failures and conflicts stay '
                  'listed here after their notification is dismissed.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

IconData activityIcon(ActivityKind kind) {
  switch (kind) {
    case ActivityKind.uploaded:
      return Icons.upload_outlined;
    case ActivityKind.downloaded:
      return Icons.download_outlined;
    case ActivityKind.moved:
      return Icons.drive_file_move_outlined;
    case ActivityKind.copied:
      return Icons.copy_outlined;
    case ActivityKind.renamed:
      return Icons.edit_outlined;
    case ActivityKind.deleted:
      return Icons.delete_outline;
    case ActivityKind.failed:
      return Icons.error_outline;
    case ActivityKind.conflict:
      return Icons.warning_amber_outlined;
  }
}

/// One feed row: icon plus text, never colour alone.
class ActivityRow extends StatelessWidget {
  const ActivityRow({super.key, required this.entry, this.onDismiss});

  final ActivityEntry entry;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final flagged = entry.kind == ActivityKind.failed;
    final subtitle = StringBuffer()
      ..write(entry.folder)
      ..write(' · ')
      ..write(formatActivityTime(entry.at));
    if (entry.size != null) subtitle.write(' · ${entry.size} bytes');
    final semantics = StringBuffer()
      ..write(entry.kind.label)
      ..write(', ')
      ..write(entry.subject)
      ..write(', ')
      ..write(entry.folder)
      ..write(', ')
      ..write(formatActivityTime(entry.at));
    if (entry.reason != null) semantics.write(', ${entry.reason}');
    return Semantics(
      container: true,
      label: semantics.toString(),
      child: ExcludeSemantics(
        child: ListTile(
          leading: Icon(
            activityIcon(entry.kind),
            color: flagged ? theme.colorScheme.error : null,
          ),
          title: Text(entry.describe()),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(subtitle.toString()),
              if (entry.reason != null)
                Text(
                  entry.reason!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
            ],
          ),
          trailing: onDismiss == null
              ? null
              : TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
        ),
      ),
    );
  }
}

class _NotificationSection extends StatelessWidget {
  const _NotificationSection({
    required this.notifications,
    required this.onDismiss,
    required this.onDismissAll,
  });

  final List<ActivityEntry> notifications;
  final ValueChanged<String> onDismiss;
  final VoidCallback onDismissAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Needs attention',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  onPressed: onDismissAll,
                  child: const Text('Dismiss all'),
                ),
              ],
            ),
          ),
          for (final entry in notifications)
            ListTile(
              dense: true,
              leading: Icon(
                activityIcon(entry.kind),
                color: entry.kind == ActivityKind.failed
                    ? theme.colorScheme.error
                    : null,
              ),
              title: Text(entry.describe()),
              subtitle: Text(entry.reason ?? entry.folder),
              trailing: TextButton(
                onPressed: () => onDismiss(entry.id),
                child: const Text('Dismiss'),
              ),
            ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.kind,
    required this.folder,
    required this.folders,
    required this.onKind,
    required this.onFolder,
  });

  final ActivityKind? kind;
  final String? folder;
  final List<String> folders;
  final ValueChanged<ActivityKind?> onKind;
  final ValueChanged<String?> onFolder;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(
            children: [
              for (final option in <ActivityKind?>[
                null,
                ...ActivityKind.values,
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(option?.label ?? 'All'),
                    selected: kind == option,
                    onSelected: (_) => onKind(option),
                  ),
                ),
            ],
          ),
        ),
        if (folders.length > 1)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String?>(
                value: folder,
                isExpanded: true,
                hint: const Text('All folders'),
                items: [
                  const DropdownMenuItem<String?>(
                    value: null,
                    child: Text('All folders'),
                  ),
                  for (final name in folders)
                    DropdownMenuItem<String?>(value: name, child: Text(name)),
                ],
                onChanged: onFolder,
              ),
            ),
          ),
      ],
    );
  }
}

/// Local free-text search over the feed. Nothing typed here is stored or
/// transmitted: it only narrows the rows already decrypted for this session.
class _ActivitySearchField extends StatelessWidget {
  const _ActivitySearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TextField(
        key: const Key('activity-search-field'),
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: 'Search activity',
          prefixIcon: const Icon(Icons.search),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  onPressed: onClear,
                  icon: const Icon(Icons.clear),
                  tooltip: 'Clear search',
                ),
          border: const OutlineInputBorder(),
          isDense: true,
        ),
      ),
    );
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity({
    required this.filtered,
    required this.searching,
    required this.hasHistory,
  });

  final bool filtered;
  final bool searching;
  final bool hasHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = searching
        ? 'No entries match this search.'
        : filtered
        ? 'No entries match these filters.'
        : (hasHistory
              ? 'No entries match these filters.'
              : 'No activity yet.\nUploads, downloads, and file actions are listed here.');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
      ),
    );
  }
}

/// Settings dialog for the local feed: how long this device keeps entries.
///
/// The window never leaves the device and never affects stored files; choosing
/// a shorter one drops older rows immediately.
class ActivitySettingsDialog extends StatefulWidget {
  const ActivitySettingsDialog({super.key, required this.log});

  final ActivityLog log;

  @override
  State<ActivitySettingsDialog> createState() => _ActivitySettingsDialogState();
}

class _ActivitySettingsDialogState extends State<ActivitySettingsDialog> {
  late int _days = widget.log.retention.inDays;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    await widget.log.setRetention(Duration(days: _days));
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Activity settings'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'How long this device keeps its activity history. A shorter '
              'window removes older rows now; files, sync folders and sync '
              'reports are not changed, and the feed never leaves this device.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final choice in activityRetentionChoices)
              ListTile(
                key: Key('activity-retention-${choice.inDays}'),
                dense: true,
                selected: _days == choice.inDays,
                title: Text(describeRetention(choice)),
                trailing: _days == choice.inDays
                    ? const Icon(Icons.check)
                    : null,
                onTap: _saving
                    ? null
                    : () => setState(() => _days = choice.inDays),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Export dialog: the report text is shown before anything leaves the app, so
/// the choice between local names and opaque identifiers is explicit.
class ActivityExportDialog extends StatefulWidget {
  const ActivityExportDialog({super.key, required this.log});

  final ActivityLog log;

  @override
  State<ActivityExportDialog> createState() => _ActivityExportDialogState();
}

class _ActivityExportDialogState extends State<ActivityExportDialog> {
  bool _includeNames = false;
  bool _copied = false;

  String get _report => widget.log.exportText(includeLocalNames: _includeNames);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Export activity report'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A report of this device is prepared below. Local names disclose '
              'your file and folder names; the redacted report replaces them '
              'with opaque identifiers. Nothing is uploaded.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ChoiceChip(
                  label: const Text('Redacted'),
                  selected: !_includeNames,
                  onSelected: (_) => setState(() {
                    _includeNames = false;
                    _copied = false;
                  }),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  label: const Text('Include local names'),
                  selected: _includeNames,
                  onSelected: (_) => setState(() {
                    _includeNames = true;
                    _copied = false;
                  }),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              child: SingleChildScrollView(
                child: SelectableText(
                  _report,
                  key: const Key('activity-export-text'),
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _report));
            if (!mounted) return;
            setState(() => _copied = true);
          },
          child: Text(_copied ? 'Copied' : 'Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
