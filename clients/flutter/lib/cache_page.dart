import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'cache_settings.dart';
import 'download_cache.dart';

/// Device storage view for the offline download cache (#82, #199).
///
/// The page owns no network access and no keys: it only reports what is on this
/// device — including how much room the device really has left — and runs the
/// cache's own pin, remove, cleanup and limit operations. Names are resolved
/// through [nameFor], which the browser fills from locally decrypted names; an
/// entry whose name is unknown is shown by a short opaque ID rather than by a
/// guess or by ciphertext.
class DownloadCachePage extends StatefulWidget {
  const DownloadCachePage({
    super.key,
    required this.cache,
    required this.nameFor,
    this.onChanged,
    this.onLimitChanged,
    this.freeSpaceReader,
  });

  final DownloadCache cache;

  /// Local display name for a file ID, or an empty string when unknown.
  final String Function(String fileId) nameFor;

  /// Called after a mutation so the caller can refresh its own badges.
  final VoidCallback? onChanged;

  /// Persists a new limit for this device. Returns false when it was applied
  /// but could not be saved, which the page reports instead of hiding.
  final Future<bool> Function(int bytes)? onLimitChanged;

  /// Test seam for the device free-space reading; defaults to the real native
  /// call. Returning null means "this build cannot read it".
  final Future<int?> Function(Directory root)? freeSpaceReader;

  @override
  State<DownloadCachePage> createState() => _DownloadCachePageState();
}

class _DownloadCachePageState extends State<DownloadCachePage> {
  late List<CachedDownload> _entries = widget.cache.entries;
  late CacheUsage _usage = widget.cache.usage;
  String? _busyKey;
  bool _clearing = false;
  bool _changingLimit = false;

  int? _freeBytes;
  bool _freeKnown = false;

  @override
  void initState() {
    super.initState();
    unawaited(_readFreeSpace());
  }

  /// One real platform reading per refresh; a failure is shown as unavailable,
  /// never guessed from the cache size.
  Future<void> _readFreeSpace() async {
    final reader = widget.freeSpaceReader ?? deviceFreeSpaceBytes;
    int? free;
    try {
      free = await reader(widget.cache.root);
    } catch (_) {
      free = null;
    }
    if (!mounted) return;
    setState(() {
      _freeBytes = free;
      _freeKnown = true;
    });
  }

  void _reload() {
    setState(() {
      _entries = widget.cache.entries;
      _usage = widget.cache.usage;
    });
    // Removing copies changes what the volume reports as free.
    unawaited(_readFreeSpace());
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

  /// Changes the device limit: the cache evicts down at once, then the value is
  /// saved so the next launch starts with it.
  Future<void> _changeLimit() async {
    final chosen = await showDialog<int>(
      context: context,
      builder: (_) => _CacheLimitDialog(current: _usage.limitBytes),
    );
    if (chosen == null || chosen == _usage.limitBytes || !mounted) return;
    setState(() => _changingLimit = true);
    try {
      final cleanup = await widget.cache.setLimit(chosen);
      var saved = true;
      try {
        saved = await widget.onLimitChanged?.call(chosen) ?? true;
      } catch (_) {
        saved = false;
      }
      if (!mounted) return;
      _reload();
      widget.onChanged?.call();
      final parts = <String>[
        'Cache limit is now ${formatCacheBytes(chosen)}.',
        if (cleanup.removedEntries > 0)
          'Removed ${cleanup.removedEntries} cached '
              '${cleanup.removedEntries == 1 ? 'copy' : 'copies'} and reclaimed '
              '${formatCacheBytes(cleanup.freedBytes)}.',
        if (cleanup.keptPinnedEntries > 0 && _usage.pinnedBytes > chosen)
          'Kept ${cleanup.keptPinnedEntries} offline '
              '${cleanup.keptPinnedEntries == 1 ? 'copy' : 'copies'} that are '
              'larger than the limit.',
        if (!saved)
          'The limit applies now but could not be saved for the next start.',
      ];
      _report(parts.join(' '));
    } catch (e) {
      if (mounted) _report('Could not change the cache limit: $e', error: true);
    } finally {
      if (mounted) setState(() => _changingLimit = false);
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

  /// The free-space sentence: a real reading, an explicit "unavailable", or a
  /// short "checking" state before the first answer.
  String _freeSpaceLine() {
    if (!_freeKnown) return 'Checking free space on this device…';
    final free = _freeBytes;
    if (free == null) return 'Device free space is unavailable on this build.';
    return '${formatCacheBytes(free)} free on this device.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pinned = _entries.where((entry) => entry.pinned).length;
    final pinnedOverLimit = _usage.pinnedBytes > _usage.limitBytes;
    final free = _freeBytes;
    final deviceTight = free != null && free < _usage.limitBytes;
    final busy = _clearing || _changingLimit;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Offline copies & cache'),
        actions: [
          IconButton(
            onPressed: busy ? null : _changeLimit,
            icon: const Icon(Icons.tune),
            tooltip: 'Change the cache limit',
          ),
          IconButton(
            onPressed: busy ? null : _clearUnpinned,
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
                    Text(_freeSpaceLine(), style: theme.textTheme.bodySmall),
                    if (pinnedOverLimit) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Warning: the copies kept offline are larger than the '
                        'limit. They are never deleted; stop keeping some '
                        'offline to get under '
                        '${formatCacheBytes(_usage.limitBytes)}.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
                    if (deviceTight) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Warning: this device has less free space than the '
                        'cache limit. Downloads stop when the device is full; '
                        'nothing here grows to fill it.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ],
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
                  final rowBusy = _busyKey == _key(entry);
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
                          onPressed: rowBusy || busy
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
                          onPressed: rowBusy || busy
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

/// Chooses a cache limit: a preset or a typed size, validated by
/// [parseCacheLimitBytes] before it can be applied.
class _CacheLimitDialog extends StatefulWidget {
  const _CacheLimitDialog({required this.current});

  final int current;

  @override
  State<_CacheLimitDialog> createState() => _CacheLimitDialogState();
}

class _CacheLimitDialogState extends State<_CacheLimitDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: formatCacheBytes(widget.current),
  );
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _selectPreset(int bytes) {
    setState(() {
      _controller.text = formatCacheBytes(bytes);
      _error = null;
    });
  }

  void _apply() {
    final bytes = parseCacheLimitBytes(_controller.text);
    if (bytes == null) {
      setState(() {
        _error =
            'Enter a size between 16 MiB and 1 TiB, for example 750 MiB or 1.5 GiB.';
      });
      return;
    }
    Navigator.pop(context, bytes);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cache limit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Downloaded copies are evicted once they pass this size on this '
            'device. Files you keep offline are never evicted.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final preset in downloadCacheLimitPresets)
                ChoiceChip(
                  label: Text(formatCacheBytes(preset)),
                  selected: parseCacheLimitBytes(_controller.text) == preset,
                  onSelected: (_) => _selectPreset(preset),
                ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Limit',
              helperText: 'For example 750 MiB, 1.5 GiB or 2048 MiB',
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _apply(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _apply, child: const Text('Apply')),
      ],
    );
  }
}

/// Short absolute local-time stamp; no locale data is required for the tooltip.
String formatCacheTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.day}.${two(local.month)}. ${two(local.hour)}:${two(local.minute)}';
}
