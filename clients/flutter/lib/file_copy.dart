import 'package:flutter/material.dart';
import 'api.dart';
import 'native.dart';

Future<Map<String, dynamic>> copyRemoteFile({required ApiClient api,
    required int handle, required RemoteFile file, required String? parentId}) async {
  if (file.isDir) throw NativeException('Folder Copy is not supported.');
  return NativeBridge.instance.copyFileAsync(handle, {
    'baseUrl': api.baseUrl, 'token': api.token,
    'source': {'id': file.id, 'parent_id': file.parentId,
      'name_enc': file.nameEnc, 'is_dir': file.isDir, 'size': file.size,
      'favorite': file.favorite, 'revision': file.revision,
      'current_version': file.currentVersion},
    'parent_id': parentId,
  });
}

class CopyFileButton extends StatelessWidget {
  const CopyFileButton({super.key, required this.isDir, required this.busy,
    required this.onCopy});
  final bool isDir;
  final bool busy;
  final VoidCallback onCopy;
  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: isDir ? 'Folder Copy is not supported' : 'Copy file',
    icon: const Icon(Icons.copy_outlined),
    onPressed: busy || isDir ? null : onCopy,
  );
}

/// A single explicit attempt. No retry affordance after an ambiguous outcome.
class CopyFileDialog extends StatefulWidget {
  const CopyFileDialog({super.key, required this.runCopy});
  final Future<Map<String, dynamic>> Function() runCopy;
  @override
  State<CopyFileDialog> createState() => _CopyFileDialogState();
}

class _CopyFileDialogState extends State<CopyFileDialog> {
  bool _running = false;
  bool _attempted = false;
  bool _success = false;
  Future<void> _copy() async {
    if (_attempted) return;
    setState(() { _attempted = true; _running = true; });
    try {
      await widget.runCopy();
      if (mounted) setState(() => _success = true);
    } catch (_) {
      // Do not expose native/server diagnostics, URLs, names or credentials.
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    child: AlertDialog(
      title: const Text('Copy file'),
      content: Text(_running ? 'Copying encrypted metadata…' : !_attempted
        ? 'Create a separate file with the same name. Existing names are never overwritten. Folder Copy is not supported.'
        : _success ? 'Copy confirmed. Refresh the destination to see the new file.'
        : 'Copy was not confirmed. Check for a name collision or changed entry. Refresh the destination before starting another copy: a lost response may already have committed. Do not blindly retry.'),
      actions: [
        if (!_attempted) FilledButton(onPressed: _copy, child: const Text('Copy')),
        TextButton(onPressed: _running ? null : () => Navigator.pop(context, _attempted),
          child: Text(_attempted ? 'Refresh' : 'Cancel')),
      ],
    ),
  );
}
