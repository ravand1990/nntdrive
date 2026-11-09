import 'package:flutter/material.dart';
import 'api.dart';
import 'native.dart';

class MoveDestination {
  const MoveDestination(this.parentId);
  final String? parentId;
}

/// Navigates fresh remote folders; no local paths or plaintext go to the API.
class MoveDialog extends StatefulWidget {
  const MoveDialog({super.key, required this.api, required this.handle, required this.source, this.copy = false});
  final bool copy;
  final ApiClient api;
  final int handle;
  final RemoteFile source;
  @override
  State<MoveDialog> createState() => _MoveDialogState();
}

class _MoveDialogState extends State<MoveDialog> {
  final List<({String id, String name})> _path = [];
  List<({RemoteFile file, String name})> _folders = [];
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
      final entries = await widget.api.listFiles(parentId: _parent);
      final folders = <({RemoteFile file, String name})>[];
      for (final entry in entries) {
        if (!entry.isDir || entry.id == widget.source.id) continue;
        folders.add((file: entry, name: NativeBridge.instance.openName(widget.handle, entry.id, entry.nameEnc)));
      }
      if (!mounted || generation != _generation) return;
      setState(() => _folders = folders);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = 'Cannot read destination folders. Refresh and try again.');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
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
        ListTile(enabled: !_loading, leading: const Icon(Icons.folder), title: Text(folder.name), onTap: () { _path.add((id: folder.file.id, name: folder.name)); _load(); }),
      ])),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: _loading || _error != null || _parent == widget.source.parentId ? null : () => Navigator.pop(context, MoveDestination(_parent)), child: Text(widget.copy ? 'Copy here' : 'Move here')),
    ],
  );
}
