import 'package:flutter/material.dart';
import 'api.dart';
import 'native.dart';
import 'session_operations.dart';

class MoveDestination {
  const MoveDestination(this.parentId);
  final String? parentId;
}

/// Navigates fresh remote folders; no local paths or plaintext go to the API.
///
/// Fixed account spaces (#95) are ordinary top-level folders, so the picker
/// lists them like any other destination. They are labelled with the space
/// they represent, and leaving the auto-synced Global space for a device space
/// asks for confirmation: that is the one move that changes what other devices
/// receive automatically. Space metadata is advisory — when the server cannot
/// report it, the picker still moves files and only shows no labels.
class MoveDialog extends StatefulWidget {
  const MoveDialog({super.key, required this.api, required this.handle,
    required this.source, this.copy = false, this.operations,
    this.sourceSpaceRootId});
  final SessionOperations? operations;
  final bool copy;
  final ApiClient api;
  final int handle;
  final RemoteFile source;

  /// The fixed space (Global or one device space) that contains [source], or
  /// null when the source is not inside one. The caller knows this from the
  /// folder trail it is browsing; the dialog never guesses an ancestry.
  final String? sourceSpaceRootId;

  @override
  State<MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<MoveDialog> {
  final List<({String id, String name})> _path = [];
  List<({RemoteFile file, String name})> _folders = [];
  List<AccountRoot> _roots = [];
  bool _loading = true;
  String? _error;
  int _generation = 0;
  String? get _parent => _path.lastOrNull?.id;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() { _loading = true; _error = null; });
    try {
      // Own each listing/decryption workflow, never the idle dialog lifetime.
      final loaded = await (widget.operations?.run(widget.handle, _loadAll)
          ?? _loadAll());
      if (!mounted || generation != _generation) return;
      setState(() {
        _folders = loaded.folders;
        _roots = loaded.roots;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = 'Cannot read destination folders. Refresh and try again.');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<({List<({RemoteFile file, String name})> folders,
      List<AccountRoot> roots})> _loadAll() async {
    // Space metadata is a labelling aid: an older server or a failure here must
    // never stop a move, so this read is best-effort and never blocks folders.
    var roots = <AccountRoot>[];
    try {
      roots = await widget.api.listRoots();
    } catch (_) {
      roots = <AccountRoot>[];
    }
    final entries = await widget.api.listFiles(parentId: _parent);
    return (
      folders: [
        for (final entry in entries)
          if (entry.isDir && entry.id != widget.source.id)
            (file: entry, name: NativeBridge.instance.openName(
              widget.handle, entry.id, entry.nameEnc))
      ],
      roots: roots,
    );
  }

  AccountRoot? _rootFor(String? nodeId) {
    if (nodeId == null) return null;
    for (final root in _roots) {
      if (root.nodeId == nodeId) return root;
    }
    return null;
  }

  /// The fixed space the current destination is inside, or null at the account
  /// root, where no space has been entered yet.
  AccountRoot? get _destinationSpace =>
      _path.isEmpty ? null : _rootFor(_path.first.id);

  AccountRoot? get _sourceSpace => _rootFor(widget.sourceSpaceRootId);

  /// Plain-language warning when this move stops the item syncing everywhere.
  /// Null for a copy, for a move that stays in Global, and when the spaces are
  /// unknown, so an older server behaves exactly as before.
  String? get _leavingGlobalWarning {
    if (widget.copy) return null;
    final source = _sourceSpace;
    final destination = _destinationSpace;
    if (source == null || !source.isGlobal) return null;
    if (destination == null || destination.nodeId == source.nodeId) return null;
    final target = destination.deviceName?.isNotEmpty == true
        ? destination.deviceName!
        : 'that device space';
    return 'This item stops syncing automatically to your other devices. '
        'It stays in $target and every device in this account can still open it.';
  }

  Future<void> _pick() async {
    final destination = _parent;
    final warning = _leavingGlobalWarning;
    if (warning != null) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Move out of Global?'),
          content: Text(warning),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, true),
              child: const Text('Move')),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    if (!mounted) return;
    Navigator.pop(context, MoveDestination(destination));
  }

  String? _spaceSubtitle(RemoteFile entry) {
    final root = _rootFor(entry.id);
    if (root == null) return null;
    if (root.isGlobal) return 'Global space · synced on every device';
    if (root.deviceRevoked) return 'Device space · device revoked, files remain';
    if (root.stale) return 'Device space · device offline, files remain';
    return 'Device space · on demand on this device';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.copy ? (widget.source.isDir ? 'Copy folder to…' : 'Copy file to…') : 'Move to…'),
    content: SizedBox(width: 420, height: 320, child: Column(children: [
      Row(children: [
        IconButton(tooltip: 'Up', onPressed: _loading || _path.isEmpty ? null : () { _path.removeLast(); _load(); }, icon: const Icon(Icons.arrow_upward)),
        Expanded(child: Text(_path.isEmpty ? 'Root' : _path.map((p) => p.name).join(' / '))),
      ]),
      if (_loading) const LinearProgressIndicator(),
      if (_error != null) Text(_error!),
      Expanded(child: ListView(children: [for (final folder in _folders)
        ListTile(enabled: !_loading, leading: const Icon(Icons.folder), title: Text(folder.name),
          subtitle: _spaceSubtitle(folder.file) == null ? null : Text(_spaceSubtitle(folder.file)!),
          onTap: () { _path.add((id: folder.file.id, name: folder.name)); _load(); }),
      ])),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _loading || _error != null || _parent == widget.source.parentId ? null : _pick, child: Text(widget.copy ? 'Copy here' : 'Move here')),
    ],
  );
}
