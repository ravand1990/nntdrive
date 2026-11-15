import 'package:flutter/material.dart';

import 'api.dart';
import 'native.dart';
import 'session_operations.dart';

/// A folder picked in [FolderPickerDialog].
///
/// A null [id] is the account root, which callers read as "the whole account"
/// or "My files" depending on the question they asked.
class FolderChoice {
  const FolderChoice(this.id, this.name);

  final String? id;
  final String name;

  bool get isRoot => id == null;
}

/// Navigates live remote folders for a caller that needs a destination or a
/// scope but should not own an API client or a key handle.
///
/// Listings come from the backend and sealed names are opened on the device;
/// the dialog returns only an ID and local plaintext, so nothing plaintext is
/// sent anywhere. The caller's [operations] keep each listing owned by the
/// session, so a picker abandoned mid-listing never keeps the app alive.
class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({
    super.key,
    required this.api,
    required this.handle,
    this.operations,
    this.title = 'Choose a folder',
    this.confirmLabel = 'Use this folder',
    this.rootLabel = 'My files',
  });

  final ApiClient api;
  final int handle;
  final SessionOperations? operations;
  final String title;
  final String confirmLabel;

  /// What the caller calls the account root; "" is never shown.
  final String rootLabel;

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  final List<({String id, String name})> _path = [];
  List<({String id, String name})> _folders = [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  String? get _parent => _path.isEmpty ? null : _path.last.id;

  String get _label => _path.isEmpty
      ? widget.rootLabel
      : _path.map((entry) => entry.name).join(' / ');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loaded = await (widget.operations?.run(widget.handle, _loadFolders) ??
          _loadFolders());
      if (!mounted || generation != _generation) return;
      setState(() => _folders = loaded);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _error =
          'Cannot read folders. Check the connection and try again.');
    } finally {
      if (mounted && generation == _generation) setState(() => _loading = false);
    }
  }

  Future<List<({String id, String name})>> _loadFolders() async {
    final entries = await widget.api.listFiles(parentId: _parent);
    return [
      for (final entry in entries)
        if (entry.isDir)
          (
            id: entry.id,
            name: NativeBridge.instance
                .openName(widget.handle, entry.id, entry.nameEnc),
          ),
    ];
  }

  void _open(({String id, String name}) folder) {
    _path.add(folder);
    _load();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: SizedBox(
          width: 420,
          height: 320,
          child: Column(children: [
            Row(children: [
              IconButton(
                tooltip: 'Up',
                onPressed: _loading || _path.isEmpty
                    ? null
                    : () {
                        _path.removeLast();
                        _load();
                      },
                icon: const Icon(Icons.arrow_upward),
              ),
              Expanded(
                  child: Text(_label, overflow: TextOverflow.ellipsis)),
            ]),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            Expanded(
              child: ListView(children: [
                for (final folder in _folders)
                  ListTile(
                    enabled: !_loading,
                    leading: const Icon(Icons.folder),
                    title: Text(folder.name),
                    onTap: () => _open(folder),
                  ),
                if (!_loading && _error == null && _folders.isEmpty)
                  const ListTile(title: Text('No folders here')),
              ]),
            ),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _loading || _error != null
                ? null
                : () => Navigator.pop(context, FolderChoice(_parent, _label)),
            child: Text(widget.confirmLabel),
          ),
        ],
      );
}
