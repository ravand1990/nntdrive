import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'account_roots.dart';
import 'api.dart';
import 'native.dart';
import 'sync_controller.dart';
import 'sync_overview.dart';
import 'sync_overview_page.dart';
import 'sync_widgets.dart';

class SyncPage extends StatefulWidget {
  const SyncPage({super.key, required this.controller});
  final SyncController controller;

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  bool _adding = false;

  /// Node ID of the space whose subscription action is still running.
  String? _spaceWorking;

  SyncController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<bool> _confirmStorageAccess() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Allow shared-storage sync?'),
            content: const Text(
                'This sync engine needs Android All files access to read and write '
                'ordinary shared-storage folders. This permission covers shared '
                'storage, not only the selected folder. NNTDrive only syncs the '
                'folders you configure. You can instead use an app-private folder '
                'without this permission. Protected folders and cloud document '
                'providers are not supported. Enable access on the next screen, '
                'then return here. Older Android versions show a permission prompt.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Continue')),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _grantAccess(SyncFolderConfig folder) async {
    if (!await _confirmStorageAccess() || !mounted) return;
    try {
      final ok = await c.grantStorageAccess(folder);
      _toast(ok
          ? 'Folder synchronized.'
          : 'Access or sync was not confirmed. Check the folder error and retry.');
    } catch (_) {
      _toast(
          'Could not open storage access. Check Android app settings and retry.');
    }
  }

  Future<void> _addFolder({bool appPrivate = false}) async {
    setState(() => _adding = true);
    try {
      final path = appPrivate
          ? await c.storageAccess.privateFolder()
          : await getDirectoryPath(confirmButtonText: 'Sync this folder');
      if (path == null) return;
      if (await c.storageAccess.permissionRequired(path)) {
        if (!mounted || !await _confirmStorageAccess()) return;
        if (!await c.storageAccess.request()) {
          _toast(
              'Storage access was not granted. Try again or use app-private storage.');
          return;
        }
      }
      final ok = await c.addFolder(path);
      if (!mounted) return;
      if (!ok) {
        _toast(c.lastStatus ?? 'Could not add the folder.');
      } else {
        _toast(c.lastStatus ?? 'Folder added. Check its sync status below.');
      }
    } catch (_) {
      _toast(
          'Could not open this folder. Use an on-device folder or app-private storage.');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _toggleSpace(AccountRoot root) async {
    final label = accountRootLabel(root);
    final subscribed = c.spaceSubscribed(root);
    setState(() => _spaceWorking = root.nodeId);
    try {
      if (subscribed) {
        await c.unsubscribeSpace(root);
        if (!mounted) return;
        _toast(
            '$label is no longer synchronized on this device. Its files stay in the library.');
      } else {
        final ok = await c.subscribeSpace(root);
        if (!mounted) return;
        _toast(ok
            ? (c.lastStatus ?? '$label is synchronized on this device.')
            : (c.lastStatus ?? 'Could not sync $label on this device.'));
      }
    } on StateError {
      _toast('Wait for sync to finish, then retry.');
    } catch (_) {
      _toast('Could not change this space on this device. Retry.');
    } finally {
      if (mounted) setState(() => _spaceWorking = null);
    }
  }

  Future<void> _syncAll() async {
    await c.syncAll();
    if (!mounted) return;
    _toast(c.lastStatus ?? 'Sync finished.');
  }

  /// Opens the device-local list of everything that is not fully in sync.
  Future<void> _openOverview() async {
    final folders = c.folders.where((folder) => folder.enabled).toList();
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SyncOverviewPage(
        load: () =>
            buildUnsyncedOverview(folders: folders, inspect: c.inspectFolder),
        onSyncFolder: (folderId) async {
          final match =
              c.folders.where((folder) => folder.id == folderId).toList();
          if (match.isEmpty) return;
          await c.syncFolder(match.first);
        },
        onGrantAccess: (folderId) async {
          final match =
              c.folders.where((folder) => folder.id == folderId).toList();
          if (match.isEmpty) return false;
          return c.grantStorageAccess(match.first);
        },
      ),
    ));
  }

  /// Decrypted label for a pre-spaces folder. A name that cannot be opened is
  /// described generically rather than showing ciphertext.
  String _legacyFolderName(RemoteFile folder) {
    try {
      return NativeBridge.instance.openName(c.handle, folder.id, folder.nameEnc);
    } catch (_) {
      return 'Synced folder';
    }
  }

  Future<void> _moveLegacyFolder(RemoteFile folder) async {
    setState(() => _spaceWorking = folder.id);
    try {
      final message = await c.moveLegacyFolderIntoDeviceSpace(folder);
      if (!mounted) return;
      _toast(message);
    } catch (_) {
      if (mounted) _toast('Could not move this folder. Nothing was changed.');
    } finally {
      if (mounted) setState(() => _spaceWorking = null);
    }
  }

  Future<void> _applyQueuedMoves() async {
    await c.applyPendingMoves();
    if (!mounted) return;
    _toast(c.lastStatus ?? 'Queued moves checked.');
  }

  Future<void> _discardQueuedMoves() async {
    await c.discardPendingMoves();
    if (mounted) _toast(c.lastStatus ?? 'Queued moves were discarded.');
  }

  Future<void> _remove(SyncFolderConfig folder) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove sync folder?'),
        content: Text(
          '“${folder.name}” will no longer be synchronized. Local files and the '
          'remote copy are kept; only the sync relationship and its local journal are removed.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) await c.removeFolder(folder);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _selectiveSync(SyncFolderConfig folder) async {
    final excluded = List<String>.from(folder.excluded);
    final result = await showDialog<List<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final theme = Theme.of(context);
          // Rebuilt on every chip change, so the warning appears and disappears
          // while the user edits the exclusions.
          final shareWarning = globalExclusionWarning(
            remoteRootId: folder.remoteRootId,
            roots: c.accountRoots,
            excluded: excluded,
          );
          return AlertDialog(
            title: Text('Selective sync — ${folder.name}'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Excluded folders stop synchronizing. Existing local and remote files are kept; '
                    'changes on either side are ignored until you include the folder again.',
                  ),
                  if (shareWarning != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber_outlined,
                              size: 18,
                              color: theme.colorScheme.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              shareWarning,
                              style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (excluded.isEmpty)
                    const Text('Everything in this folder is synchronized.')
                  else
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: excluded
                          .map((path) => InputChip(
                                label: Text(path),
                                onDeleted: () =>
                                    setDialogState(() => excluded.remove(path)),
                              ))
                          .toList(),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: () async {
                      try {
                        final picked = await getDirectoryPath(
                          initialDirectory: folder.localPath,
                          confirmButtonText: 'Exclude this folder',
                        );
                        if (picked == null) return;
                        final rel = p
                            .relative(picked, from: folder.localPath)
                            .replaceAll('\\', '/');
                        if (rel == '.' ||
                            rel.startsWith('../') ||
                            p.isAbsolute(rel)) {
                          _toast(
                              'Choose a subfolder inside ${folder.localPath}.');
                          return;
                        }
                        if (!excluded.contains(rel)) {
                          setDialogState(() => excluded.add(rel));
                        }
                      } catch (e) {
                        _toast('Folder picker failed: $e');
                      }
                    },
                    icon: const Icon(Icons.folder_off_outlined),
                    label: const Text('Exclude a subfolder'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () => Navigator.pop(context, excluded),
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (result != null) {
      await c.setExcluded(folder, result);
      if (mounted) {
        _toast(globalExclusionWarning(
                  remoteRootId: folder.remoteRootId,
                  roots: c.accountRoots,
                  excluded: result,
                ) ==
                null
            ? 'Selective sync updated.'
            : 'Selective sync updated. Global is no longer fully shared with your other devices.');
      }
    }
  }

  Future<void> _reveal(String absolutePath) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', ['/select,', absolutePath]);
      } else if (Platform.isMacOS) {
        await Process.run('open', ['-R', absolutePath]);
      } else {
        await Process.run('xdg-open', [p.dirname(absolutePath)]);
      }
    } catch (e) {
      _toast('Could not open file manager: $e');
    }
  }

  Future<void> _showConflicts() async {
    final conflicts = <(SyncFolderConfig, String)>[
      for (final folder in c.folders)
        for (final path in folder.conflictFiles) (folder, path)
    ];
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Conflicts (${conflicts.length})'),
        content: SizedBox(
          width: 620,
          child: conflicts.isEmpty
              ? const Text('No conflict copies found.')
              : ListView.separated(
                  shrinkWrap: true,
                  itemCount: conflicts.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final (folder, path) = conflicts[i];
                    final absolute = p.join(folder.localPath, path);
                    return ListTile(
                      dense: true,
                      title: Text(path),
                      subtitle: Text('${folder.name} · conflict copy'),
                      trailing: Wrap(children: [
                        TextButton(
                            onPressed: () => _reveal(absolute),
                            child: const Text('Show')),
                        TextButton(
                            onPressed: folder.running || c.syncing
                                ? null
                                : () async {
                                    Navigator.pop(context);
                                    final original = originalConflictPath(path);
                                    if (original == null || !mounted) return;
                                    final choice = await showDialog<String>(
                                        context: this.context,
                                        builder: (_) => ConflictChoiceDialog(
                                            original: original, copy: path));
                                    if (choice == null || !mounted) return;
                                    try {
                                      await c.resolveConflict(
                                          folder, path, choice);
                                    } catch (e) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(this.context)
                                            .showSnackBar(
                                                SnackBar(content: Text('$e')));
                                      }
                                    }
                                  },
                            child: const Text('Resolve')),
                      ]),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync folders'),
        actions: [
          if (c.conflictCount > 0)
            IconButton(
              tooltip: 'Review ${c.conflictCount} conflict copy(ies)',
              onPressed: _showConflicts,
              icon: Badge(
                label: Text('${c.conflictCount}'),
                child: const Icon(Icons.warning_amber_outlined),
              ),
            ),
          IconButton(
            tooltip: 'Sync all now',
            onPressed: c.syncing ? null : _syncAll,
            icon: c.syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Bidirectional folder sync',
                      style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  const Text(
                    'The first folder is your base folder; add as many additional folders as you like. '
                    'Content is encrypted before it leaves this device. Local files stay readable on disk '
                    'unless you use full-disk encryption or a vault.',
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      const Icon(Icons.schedule, size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          c.paused
                              ? 'Automatic sync is paused.'
                              : 'Automatic sync every ${SyncController.autoSyncInterval.inMinutes} minutes while the app is open.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Switch(
                        value: !c.paused,
                        onChanged: (enabled) => c.setPaused(!enabled),
                      ),
                    ],
                  ),
                  if (c.lastStatus != null) ...[
                    const SizedBox(height: 6),
                    Text(c.lastStatus!, style: theme.textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: ListTile(
              leading: const Icon(Icons.fact_check_outlined),
              title: const Text('Not synced'),
              subtitle: const Text(
                  'Every cloud-only, local-only, pending, failed, conflict, skipped or blocked item on this device.'),
              trailing: const Icon(Icons.chevron_right),
              onTap: c.folders.isEmpty ? null : _openOverview,
            ),
          ),
          if (c.pendingMoveCount > 0) ...[
            Card(
              color: c.pendingMoveAttention > 0
                  ? theme.colorScheme.errorContainer
                  : theme.colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: const Icon(Icons.swap_horiz),
                title: Text(c.pendingMoveCount == 1
                    ? '1 queued move waiting'
                    : '${c.pendingMoveCount} queued moves waiting'),
                subtitle: Text(
                  c.pendingMoveAttention > 0
                      ? 'A queued move could not be applied because the item or its destination changed on another device. Nothing was overwritten.'
                      : 'Saved on this device when the server was unreachable. They are applied automatically after the next unlock or sync.',
                ),
                trailing: c.pendingMoveAttention > 0
                    ? TextButton(
                        onPressed: c.syncing ? null : _discardQueuedMoves,
                        child: const Text('Discard'),
                      )
                    : TextButton(
                        onPressed: c.syncing ? null : _applyQueuedMoves,
                        child: const Text('Apply now'),
                      ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (c.conflictCount > 0) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: const Icon(Icons.warning_amber_outlined),
                title:
                    Text('${c.conflictCount} conflict copy(ies) need review'),
                subtitle: const Text(
                  'Both versions were kept. Review and choose Keep mine, Keep theirs, or Keep both; recovery files stay synced.',
                ),
                trailing: TextButton(
                  onPressed: _showConflicts,
                  child: const Text('Review'),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (c.folders.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                children: [
                  const Icon(Icons.folder_copy_outlined, size: 56),
                  const SizedBox(height: 12),
                  Text('Choose your base folder',
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 6),
                  const Text(
                    'Pick a folder on this device. Its contents will be encrypted and mirrored to your '
                    'encrypted library, and remote changes will be written back.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _adding ? null : _addFolder,
                    icon: _adding
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.create_new_folder_outlined),
                    label: const Text('Select base folder'),
                  ),
                  if (c.storageAccess.isAndroid)
                    TextButton(
                      onPressed:
                          _adding ? null : () => _addFolder(appPrivate: true),
                      child:
                          const Text('Use app-private folder (no permission)'),
                    ),
                ],
              ),
            )
          else ...[
            for (var i = 0; i < c.folders.length; i++)
              _folderCard(c.folders[i], i),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _adding ? null : _addFolder,
                    icon: _adding
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.add),
                    label: const Text('Add another folder'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: c.syncing || c.paused ? null : _syncAll,
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync all now'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          _accountSpacesCard(theme),
        ],
      ),
    );
  }

  /// Global and per-device spaces. They are ordinary folders in the encrypted
  /// library, but the fixed roots add device presence that the file listing
  /// does not carry: which device each space belongs to and whether it is
  /// currently offline or revoked. Stale spaces stay usable.
  Widget _accountSpacesCard(ThemeData theme) {
    final roots = c.accountRoots;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.public, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Account spaces',
                      style: theme.textTheme.titleMedium),
                ),
                if (c.rootsLoading)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: 'Refresh account spaces',
                    onPressed: () => c.refreshAccountRoots(),
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'The Global space is synchronized automatically on every device. '
              'Each device also has its own space; sync it here to keep a copy on this device. '
              'Both are ordinary folders in your encrypted library.',
            ),
            if (c.rootsError != null) ...[
              const SizedBox(height: 8),
              Text(c.rootsError!, style: theme.textTheme.bodySmall),
              TextButton(
                onPressed: () => c.refreshAccountRoots(),
                child: const Text('Retry'),
              ),
            ],
            if (c.rootsWarning != null) ...[
              const SizedBox(height: 8),
              Text(c.rootsWarning!, style: theme.textTheme.bodySmall),
            ],
            for (final root in roots)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading:
                    Icon(root.isGlobal ? Icons.public : Icons.devices_outlined),
                title: Text(accountRootLabel(root)),
                subtitle: Text(accountRootStatus(root)),
                trailing: _spaceWorking == root.nodeId
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _spaceWorking == null
                            ? () => _toggleSpace(root)
                            : null,
                        child: Text(c.spaceSubscribed(root)
                            ? 'Stop syncing'
                            : 'Sync to this device'),
                      ),
              ),
            if (roots.isEmpty && !c.rootsLoading && c.rootsError == null) ...[
              const SizedBox(height: 6),
              Text(
                'No spaces yet. They are created automatically the next time this client signs in.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (c.legacySpaceFolders.isNotEmpty) ...[
              const Divider(height: 20),
              Text('Folders outside your spaces',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                'These synced folders were created before account spaces existed, '
                'so their remote folders still sit at the account root. Moving one '
                "into this device's space keeps its files, versions and local sync; "
                'nothing is deleted.',
                style: theme.textTheme.bodySmall,
              ),
              for (final folder in c.legacySpaceFolders)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_copy_outlined),
                  title: Text(_legacyFolderName(folder)),
                  subtitle: const Text('Account root · outside every space'),
                  trailing: _spaceWorking == folder.id
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: _spaceWorking == null
                              ? () => _moveLegacyFolder(folder)
                              : null,
                          child: const Text('Move into device space'),
                        ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _folderCard(SyncFolderConfig folder, int index) {
    final theme = Theme.of(context);
    final lastSync = folder.lastSync == null
        ? 'Never synced'
        : 'Last sync ${DateTime.parse(folder.lastSync!).toLocal().toString().substring(0, 19)}';
    final counts = folder.lastReport == null
        ? ''
        : ' · ↑${folder.uploaded} ↓${folder.downloaded}'
            '${folder.conflicts > 0 ? ' · ${folder.conflicts} conflict(s)' : ''}';
    // Global stops being fully shared as soon as part of it is excluded.
    final shareMarker = globalExclusionMarker(
      remoteRootId: folder.remoteRootId,
      roots: c.accountRoots,
      excluded: folder.excluded,
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(index == 0 ? Icons.home_outlined : Icons.folder_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${index == 0 ? 'Base folder' : 'Additional folder'} · ${folder.name}',
                        style: theme.textTheme.titleSmall,
                      ),
                      Text(folder.localPath, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
                Switch(
                  value: folder.enabled,
                  onChanged:
                      folder.running ? null : (v) => c.setEnabled(folder, v),
                ),
                PopupMenuButton<String>(
                  enabled: !folder.running,
                  onSelected: (value) {
                    if (value == 'sync') c.syncFolder(folder);
                    if (value == 'selective') _selectiveSync(folder);
                    if (value == 'conflicts') _showConflicts();
                    if (value == 'remove') _remove(folder);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(value: 'sync', child: Text('Sync now')),
                    PopupMenuItem(
                        value: 'selective', child: Text('Selective sync…')),
                    PopupMenuItem(
                        value: 'conflicts', child: Text('Review conflicts…')),
                    PopupMenuItem(value: 'remove', child: Text('Remove')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('$lastSync$counts', style: theme.textTheme.bodySmall),
            if (shareMarker != null) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_outlined,
                      size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(shareMarker,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error)),
                  ),
                ],
              ),
            ],
            if (folder.progress != null)
              SyncTransferProgress(event: folder.progress!),
            if (folder.running && folder.progress == null)
              const LinearProgressIndicator(),
            if (folder.storageAccessRequired)
              TextButton.icon(
                onPressed: folder.running ? null : () => _grantAccess(folder),
                icon: const Icon(Icons.folder_open),
                label: const Text('Grant storage access and retry'),
              ),
            if (folder.hasErrors) ...[
              const SizedBox(height: 6),
              Text(
                folder.lastError ?? 'Some files could not be synchronized.',
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
