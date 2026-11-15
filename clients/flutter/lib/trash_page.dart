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
  });

  /// Reads the current trash listing from the backend.
  final Future<TrashListing> Function() load;

  /// Opens the sealed names of [entries] in order, or an empty list when the
  /// names cannot be opened (they are shown as unavailable, never as ciphertext).
  final Future<List<String>> Function(List<TrashEntry> entries) decrypt;

  /// Restores one item. `toRoot` is used when the original folder is gone.
  final Future<void> Function(String id, {bool toRoot}) restore;

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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
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
          .showSnackBar(SnackBar(content: Text(_describe(e))));
    }
  }

  String _describe(Object error) {
    if (error is ApiException) {
      if (error.status == 410) {
        return 'This item passed the retention window and cannot be restored.';
      }
      if (error.status == 409) {
        return 'This item changed or its folder is gone. Refresh and try again.';
      }
      return error.message;
    }
    return 'The trash could not be loaded. Check the connection and try again.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trash'),
        actions: [
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
  });

  final String name;
  final TrashEntry entry;
  final bool busy;
  final VoidCallback? onRestore;

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
          : entry.expired
              ? const Text('Cannot restore')
              : TextButton.icon(
                  onPressed: onRestore,
                  icon: const Icon(Icons.restore),
                  label: const Text('Restore'),
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
