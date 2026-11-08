import 'package:flutter/material.dart';

/// Available only inside the unlocked account UI. No automatic retry or GC.
class ReferenceBackfillDialog extends StatefulWidget {
  const ReferenceBackfillDialog({super.key, required this.runBatch});
  final Future<Map<String, dynamic>> Function() runBatch;

  @override
  State<ReferenceBackfillDialog> createState() => _ReferenceBackfillDialogState();
}

class _ReferenceBackfillDialogState extends State<ReferenceBackfillDialog> {
  bool _running = false;
  bool _started = false;
  bool _more = true;
  String? _result;

  Future<void> _run() async {
    if (_running) return;
    setState(() { _running = true; _started = true; });
    String result;
    bool more = true;
    try {
      final report = await widget.runBatch();
      more = report['more'] == true;
      result = '${report['completed']} revision(s) confirmed in this batch. '
          '${report['failed'] == true ? 'Stopped on an error or timeout. Check your connection and unlocked account keys, then retry safely.' : more ? 'More revisions remain. Continue with another batch.' : 'No more incomplete revisions in this pass. GC rechecks completeness; this does not enable cleanup.'}';
    } catch (_) {
      result = 'Backfill failed. Check your connection, native core and unlocked account, then retry safely. Previously confirmed references are preserved.';
    }
    if (!mounted) return;
    setState(() { _running = false; _more = more; _result = result; });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_running,
    child: AlertDialog(
      title: const Text('Prepare legacy references'),
      content: SingleChildScrollView(child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Decrypt and validate historical manifests locally for this account, including deleted files. Only opaque chunk IDs are sent. No files or NNTP articles are deleted. Upgrade all clients before admin cleanup. Each explicit batch handles at most 200 revisions for up to 60 seconds; retries are safe.'),
          if (_running) const LinearProgressIndicator(),
          if (_result != null) Text(_result!),
        ],
      )),
      actions: [
        TextButton(onPressed: _running ? null : () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(onPressed: _running || !_more ? null : _run,
          child: Text(_running ? 'Preparing…' : _started ? 'Continue / retry' : 'Start batch')),
      ],
    ),
  );
}
