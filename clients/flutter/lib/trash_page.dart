import 'package:flutter/material.dart';

import 'api.dart';

/// The device-independent trash view: every deleted item the account can still
/// restore, how long it stays restorable, and one explicit restore action.
///
/// Names arrive as sealed envelopes and are decrypted locally through the
/// injected [decrypt] callback, so the page never handles plaintext in a place
/// that could reach the server. The page owns no API client itself; the
/// callback seams keep it testable and keep session lifetime handling in the
/// caller.
class TrashPage extends StatefulWidget {
  const TrashPage({
    super.key,
    required this.load,
    required this.decrypt,
    required this.restore,
    required this.purge,
    required this.emptyTrash,
    this.previewRewind,
    this.applyRewind,
    this.decryptRewind,
  });

  /// Reads the current trash listing from the backend.
  final Future<TrashListing> Function() load;

  /// Opens the sealed names of [entries] in order, or an empty list when the
  /// names cannot be opened (they are shown as unavailable, never as ciphertext).
  final Future<List<String>> Function(List<TrashEntry> entries) decrypt;

  /// Restores one item. `toRoot` is used when the original folder is gone.
  final Future<void> Function(String id, {bool toRoot}) restore;

  /// Permanently deletes one item and everything inside it.
  final Future<void> Function(String id) purge;

  /// Permanently deletes every trashed item of this account.
  final Future<void> Function() emptyTrash;

  /// Plans an account-wide rewind to an earlier instant. When null the rewind
  /// action is not offered at all.
  final Future<RewindPreview> Function(DateTime before)? previewRewind;

  /// Applies a plan that the user has just seen and confirmed.
  final Future<RewindResult> Function(DateTime before, List<RewindItem> items)?
      applyRewind;

  /// Opens the sealed names of rewind rows, in order.
  final Future<List<String>> Function(List<RewindItem> items)? decryptRewind;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  List<TrashEntry> _entries = [];
  List<String> _names = [];
  int _retentionDays = 0;
  bool _loading = true;
  String? _error;
  String? _busyId;
  bool _emptying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final listing = await widget.load();
      List<String> names;
      try {
        names = await widget.decrypt(listing.files);
      } catch (_) {
        names = List.filled(listing.files.length, '');
      }
      if (!mounted) return;
      setState(() {
        _entries = listing.files;
        _names = names;
        _retentionDays = listing.retentionDays;
        _loading = false;
        _busyId = null;
        _emptying = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e, fallback: _trashLoadError);
        _loading = false;
      });
    }
  }

  String _name(int index) {
    final name = index < _names.length ? _names[index] : '';
    return name.isEmpty ? 'Name unavailable' : name;
  }

  Future<void> _restore(TrashEntry entry) async {
    var toRoot = false;
    if (!entry.parentPresent) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('The original folder is gone'),
          content: const Text(
              'This item was deleted from a folder that no longer exists. '
              'Restore it to My files instead?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Restore to My files')),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      toRoot = true;
    }
    setState(() => _busyId = entry.id);
    try {
      await widget.restore(entry.id, toRoot: toRoot);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Restored ${_name(_entries.indexOf(entry))}')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_describeError(e))));
    }
  }

  Future<void> _purge(TrashEntry entry) async {
    final name = _name(_entries.indexOf(entry));
    final what =
        entry.isDir ? 'the folder "$name" and everything inside it' : '"$name"';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text('This removes $what from your account for good and '
            'cannot be undone. Files already posted to Usenet cannot be '
            'retracted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete permanently')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyId = entry.id);
    try {
      await widget.purge(entry.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted $name permanently')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busyId = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_describeError(e))));
    }
  }

  /// Plans a rewind, shows the plan and applies only what the user confirmed.
  Future<void> _openRewind() async {
    final preview = widget.previewRewind;
    final apply = widget.applyRewind;
    if (preview == null || apply == null) return;
    final result = await showDialog<RewindResult>(
      context: context,
      builder: (_) => _RewindDialog(
        preview: preview,
        apply: apply,
        decrypt: widget.decryptRewind ?? _unavailableRewindNames,
      ),
    );
    if (result == null || !mounted) return;
    final applied = result.applied;
    final failed = result.failed.length;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(failed == 0
            ? 'Rewound $applied ${applied == 1 ? 'file' : 'files'} to '
                '${applied == 1 ? 'its' : 'their'} earlier version'
            : 'Rewound $applied files; $failed could not be changed. '
                'Preview again to see what is left.')));
  }

  Future<void> _emptyTrash() async {
    final count = _entries.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty the trash?'),
        content: Text('This permanently removes $count deleted '
            '${count == 1 ? 'item' : 'items'} from your account for good and '
            'cannot be undone. Files already posted to Usenet cannot be '
            'retracted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Empty trash')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _emptying = true);
    try {
      await widget.emptyTrash();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Trash emptied')));
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _emptying = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_describeError(e))));
    }
  }


  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
          if (widget.previewRewind != null && widget.applyRewind != null)
            IconButton(
                onPressed: _loading || _busyId != null ? null : _openRewind,
                tooltip: 'Rewind to an earlier date',
                icon: const Icon(Icons.history)),
          if (_emptying)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))),
            )
          else
            IconButton(
                onPressed: _loading || _entries.isEmpty || _busyId != null
                    ? null
                    : _emptyTrash,
                tooltip: 'Empty trash',
                icon: const Icon(Icons.delete_sweep)),
          IconButton(
              onPressed: _loading ? null : _load,
              tooltip: 'Refresh trash',
              icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                            onPressed: _load,
                            child: const Text('Try again')),
                      ],
                    ),
                  ),
                )
              : _entries.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Nothing in the trash.',
                            textAlign: TextAlign.center),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView.separated(
                        itemCount: _entries.length + 1,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, i) {
                          if (i == 0) {
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              child: Text(
                                'Deleted items stay restorable for '
                                '$_retentionDays days. Deleted files keep their '
                                'version history; content already posted to '
                                'Usenet cannot be physically removed.',
                                style: theme.textTheme.bodySmall,
                              ),
                            );
                          }
                          final entry = _entries[i - 1];
                          return _TrashRow(
                            name: _name(i - 1),
                            entry: entry,
                            busy: _busyId == entry.id,
                            onRestore: entry.expired || _busyId != null
                                ? null
                                : () => _restore(entry),
                            onPurge: _busyId != null || _emptying
                                ? null
                                : () => _purge(entry),
                          );
                        },
                      ),
                    ),
    );
  }
}

class _TrashRow extends StatelessWidget {
  const _TrashRow({
    required this.name,
    required this.entry,
    required this.busy,
    required this.onRestore,
    required this.onPurge,
  });

  final String name;
  final TrashEntry entry;
  final bool busy;
  final VoidCallback? onRestore;
  final VoidCallback? onPurge;

  String get _status {
    if (entry.expired) return 'Retention passed';
    final days = entry.daysLeft;
    return days <= 1 ? '1 day left' : '$days days left';
  }

  String get _details {
    final kind = entry.isDir ? 'Folder' : _formatBytes(entry.size);
    final deleted = entry.deletedAt;
    final when = deleted == null
        ? ''
        : ' · deleted ${deleted.year.toString().padLeft(4, '0')}-'
            '${deleted.month.toString().padLeft(2, '0')}-'
            '${deleted.day.toString().padLeft(2, '0')}';
    return '$kind$when · $_status';
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        entry.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
        semanticLabel: entry.isDir ? 'Deleted folder' : 'Deleted file',
      ),
      title: Text(name),
      subtitle: Text(_details),
      trailing: busy
          ? const SizedBox(
              width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (entry.expired)
                  const Text('Cannot restore')
                else
                  TextButton.icon(
                    onPressed: onRestore,
                    icon: const Icon(Icons.restore),
                    label: const Text('Restore'),
                  ),
                IconButton(
                  onPressed: onPurge,
                  tooltip: 'Delete permanently',
                  icon: const Icon(Icons.delete_forever),
                ),
              ],
            ),
    );
  }
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

const _trashLoadError =
    'The trash could not be loaded. Check the connection and try again.';
const _trashActionError =
    'This item could not be changed. Check the connection and try again.';

/// Plain-language reasons; never a raw status line, stack detail or ciphertext.
String _describeError(Object error, {String fallback = _trashActionError}) {
  if (error is ApiException) {
    if (error.status == 410) {
      return 'This item passed the retention window and cannot be restored.';
    }
    if (error.status == 409) {
      return 'This item changed or its folder is gone. Refresh and try again.';
    }
    // Network failures and server faults carry no useful text for a user.
    if (error.status == 0 || error.status >= 500) return fallback;
    return error.message;
  }
  return fallback;
}

/// Rewind rows whose sealed names could not be opened stay unreadable rather
/// than showing ciphertext.
Future<List<String>> _unavailableRewindNames(List<RewindItem> items) async =>
    items.map((_) => 'Name unavailable').toList();

/// Always shows the plan before changing anything: a rewind is only applied
/// after the user saw which files it would change at which date.
class _RewindDialog extends StatefulWidget {
  const _RewindDialog({
    required this.preview,
    required this.apply,
    required this.decrypt,
  });

  final Future<RewindPreview> Function(DateTime before) preview;
  final Future<RewindResult> Function(DateTime before, List<RewindItem> items)
      apply;
  final Future<List<String>> Function(List<RewindItem> items) decrypt;

  @override
  State<_RewindDialog> createState() => _RewindDialogState();
}

class _RewindDialogState extends State<_RewindDialog> {
  static const _presets = <({String label, int days})>[
    (label: '1 day ago', days: 1),
    (label: '7 days ago', days: 7),
    (label: '30 days ago', days: 30),
  ];

  int? _presetDays;
  DateTime? _before;
  RewindPreview? _plan;
  List<String> _names = const [];
  bool _loading = false;
  bool _applying = false;
  String? _error;

  Future<void> _choose(DateTime before, {int? preset}) async {
    setState(() {
      _presetDays = preset;
      _before = before;
      _plan = null;
      _names = const [];
      _error = null;
      _loading = true;
    });
    try {
      final plan = await widget.preview(before);
      List<String> names = const [];
      if (plan.items.isNotEmpty) {
        try {
          names = await widget.decrypt(plan.items);
        } catch (_) {
          names = const []; // Unreadable names are never shown as ciphertext.
        }
      }
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _names = names;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e,
            fallback: 'The rewind plan could not be read. Check the connection '
                'and try again.');
        _loading = false;
      });
    }
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now.subtract(const Duration(days: 7)),
      firstDate: DateTime(2000),
      lastDate: now,
      helpText: 'Rewind to the end of this day',
    );
    if (picked == null || !mounted) return;
    // The end of the chosen day, so that day's versions are included.
    final end = DateTime(picked.year, picked.month, picked.day, 23, 59, 59);
    await _choose(end);
  }

  Future<void> _apply() async {
    final plan = _plan;
    final before = _before;
    if (plan == null || before == null || plan.items.isEmpty) return;
    setState(() {
      _applying = true;
      _error = null;
    });
    try {
      final result = await widget.apply(before, plan.items);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describeError(e,
            fallback: 'The rewind could not be applied. Nothing was changed by '
                'this attempt; preview again.');
        _applying = false;
      });
    }
  }

  String _when(DateTime before) {
    final local = before.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-${two(local.month)}-'
        '${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = _plan;
    final changes = plan?.items.length ?? 0;
    return AlertDialog(
      title: const Text('Rewind to an earlier date'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  'Puts files back to the version they had on that date. '
                  'Versions after it stay in history, nothing is uploaded or '
                  'removed, and items in the trash are not touched.',
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final preset in _presets)
                    ChoiceChip(
                      label: Text(preset.label),
                      selected: _presetDays == preset.days,
                      onSelected: _loading || _applying
                          ? null
                          : (_) => _choose(
                              DateTime.now()
                                  .subtract(Duration(days: preset.days)),
                              preset: preset.days),
                    ),
                  ActionChip(
                    avatar: const Icon(Icons.event, size: 18),
                    label: const Text('Pick a date'),
                    onPressed: _loading || _applying ? null : _pickDate,
                  ),
                ],
              ),
              if (_loading) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              if (plan != null) ...[
                const SizedBox(height: 16),
                Text('As of ${_when(_before ?? DateTime.now())}',
                    style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(changes == 0
                    ? 'Nothing would change.'
                    : '$changes ${changes == 1 ? 'file would' : 'files would'} '
                        'go back to an earlier version.'),
                if (plan.counts.createdAfter > 0)
                  Text('${plan.counts.createdAfter} created after that date '
                      'stay as they are.'),
                if (plan.counts.pendingReferences > 0)
                  Text('${plan.counts.pendingReferences} cannot be rewound yet '
                      'because their content references are still pending.'),
                if (changes > 0) ...[
                  const SizedBox(height: 8),
                  for (var i = 0; i < changes && i < 50; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(children: [
                        const Icon(Icons.insert_drive_file_outlined, size: 16),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            i < _names.length && _names[i].isNotEmpty
                                ? _names[i]
                                : 'Name unavailable',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ]),
                    ),
                  if (changes > 50)
                    Text('and ${changes - 50} more',
                        style: theme.textTheme.bodySmall),
                  if (plan.next != null)
                    Text(
                        'Only the first $changes changed files are shown. '
                        'Rewind again afterwards to continue with the rest.',
                        style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text('Already posted Usenet copies cannot be retracted; '
                      'this changes your account view only.',
                      style: theme.textTheme.bodySmall),
                ],
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _applying ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _applying || changes == 0 ? null : _apply,
          child: _applying
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(changes == 0
                  ? 'Rewind'
                  : 'Rewind $changes ${changes == 1 ? 'file' : 'files'}'),
        ),
      ],
    );
  }
}
