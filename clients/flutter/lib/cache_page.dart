import 'package:flutter/material.dart';

import 'download_cache.dart';

/// Device storage view for the offline download cache (#82).
///
/// The page owns no network access and no keys: it only reports what is on this
/// device and runs the cache's own pin, remove and cleanup operations. Names are
/// resolved through [nameFor], which the browser fills from locally decrypted
/// names; an entry whose name is unknown is shown by a short opaque ID rather
/// than by a guess or by ciphertext.
class DownloadCachePage extends StatefulWidget {
  const DownloadCachePage({
    super.key,
    required this.cache,
    required this.nameFor,
    this.onChanged,
  });

  final DownloadCache cache;

  /// Local display name for a file ID, or an empty string when unknown.
  final String Function(String fileId) nameFor;

  /// Called after a mutation so the caller can refresh its own badges.
  final VoidCallback? onChanged;

  @override
  State<DownloadCachePage> createState() => _DownloadCachePageState();
}

class _DownloadCachePageState extends State<DownloadCachePage> {
  late List<CachedDownload> _entries = widget.cache.entries;
  late CacheUsage _usage = widget.cache.usage;
  String? _busyKey;
  bool _clearing = false;

  void _reload() {
    setState(() {
      _entries = widget.cache.entries;
      _usage = widget.cache.usage;
    });
  }

  String _label(CachedDownload entry) {
    final name = widget.nameFor(entry.fileId);
    if (name.isNotEmpty) return name;
    final short = entry.fileId.length <= 8
        ? entry.fileId
        : entry.fileId.substring(0, 8);
    return 'Cached item $short';
  }

  String _key(CachedDownload entry) =>
      '${entry.fileId}\u0000${entry.revisionId}';

  Future<void> _togglePin(CachedDownload entry) async {
    setState(() => _busyKey = _key(entry));
    try {
      await widget.cache.setPinned(
        entry.fileId,
        entry.revisionId,
        !entry.pinned,
      );
      if (!mounted) return;
      _reload();
      widget.onChanged?.call();
      _report(
        !entry.pinned
            ? '${_label(entry)} is kept offline and will not be evicted.'
            : '${_label(entry)} can be evicted again.',
      );
    } catch (e) {
      if (mounted) {
        _report('Could not change the offline copy: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _remove(CachedDownload entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove the offline copy?'),
        content: Text(
          '${_label(entry)} stays in your account. Only this device\'s '
          'offline copy is deleted, so opening it again needs the network.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busyKey = _key(entry));
    try {
      await widget.cache.remove(entry.fileId, entry.revisionId);
      if (!mounted) return;
      _reload();
      widget.onChanged?.call();
      _report('Removed the offline copy of ${_label(entry)}.');
    } catch (e) {
      if (mounted) {
        _report('Could not remove the offline copy: $e', error: true);
      }
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _clearUnpinned() async {
    final candidates = _entries.where((entry) => !entry.pinned).length;
    if (candidates == 0) {
      _report('There is no unpinned cached copy to clear.');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear unpinned cache?'),
        content: Text(
          '$candidates cached ${candidates == 1 ? 'copy' : 'copies'} that are '
          'not kept offline will be deleted from this device. Files you kept '
          'offline stay, and nothing is deleted from your account.',
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
    if (ok != true || !mounted) return;
    setState(() => _clearing = true);
    try {
      final cleanup = await widget.cache.clearUnpinned();
      if (!mounted) return;
      _reload();
      widget.onChanged?.call();
      _report(
        cleanup.removedEntries == 0
            ? 'Nothing was removed.'
            : 'Removed ${cleanup.removedEntries} cached '
                  '${cleanup.removedEntries == 1 ? 'copy' : 'copies'} and reclaimed '
                  '${formatCacheBytes(cleanup.freedBytes)}. '
                  '${cleanup.keptPinnedEntries} kept offline.',
      );
    } catch (e) {
      if (mounted) _report('Could not clear the cache: $e', error: true);
    } finally {
      if (mounted) setState(() => _clearing = false);
    }
  }

  void _report(String message, {bool error = false}) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Theme.of(context).colorScheme.error : null,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinned = _entries.where((entry) => entry.pinned).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline copies & cache'),
        actions: [
          IconButton(
            onPressed: _clearing ? null : _clearUnpinned,
            icon: const Icon(Icons.cleaning_services_outlined),
            tooltip: 'Clear unpinned cache',
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('This device', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 6),
                    Text(
                      '${formatCacheBytes(_usage.usedBytes)} cached, of a '
                      '${formatCacheBytes(_usage.limitBytes)} limit',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      '${formatCacheBytes(_usage.pinnedBytes)} kept offline '
                      '($pinned ${pinned == 1 ? 'item' : 'items'}) · '
                      '${formatCacheBytes(_usage.headroomBytes)} left before '
                      'the oldest unpinned copy is evicted',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Only downloaded copies live here. Files inside sync '
                      'folders, local-only files and unsynced work are never '
                      'part of this cache and are never evicted.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_entries.isEmpty)
            const Expanded(
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'No downloaded copies are cached on this device.\n'
                    'Use "Keep offline" on a file to open it without the network.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.separated(
                itemCount: _entries.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final entry = _entries[index];
                  final busy = _busyKey == _key(entry);
                  return ListTile(
                    leading: Icon(
                      entry.pinned ? Icons.offline_pin : Icons.download_done,
                      semanticLabel: entry.pinned
                          ? 'Kept offline'
                          : 'Cached copy',
                    ),
                    title: Text(_label(entry)),
                    subtitle: Text(
                      '${formatCacheBytes(entry.sizeBytes)} · '
                      '${entry.pinned ? 'kept offline' : 'cache only'} · '
                      'last used ${formatCacheTime(entry.lastUsedAt)}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: busy || _clearing
                              ? null
                              : () => _togglePin(entry),
                          icon: Icon(
                            entry.pinned
                                ? Icons.push_pin
                                : Icons.push_pin_outlined,
                          ),
                          tooltip: entry.pinned
                              ? 'Stop keeping this offline'
                              : 'Keep this offline',
                        ),
                        IconButton(
                          onPressed: busy || _clearing
                              ? null
                              : () => _remove(entry),
                          icon: const Icon(Icons.delete_outline),
                          tooltip: 'Remove the offline copy',
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Byte counts in the units a person compares, matching the rest of the client.
String formatCacheBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

/// Short absolute local-time stamp; no locale data is required for the tooltip.
String formatCacheTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.day}.${two(local.month)}. ${two(local.hour)}:${two(local.minute)}';
}
