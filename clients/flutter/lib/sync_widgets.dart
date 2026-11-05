import 'package:flutter/material.dart';

/// Logical plaintext bytes, not compressed/encrypted wire traffic. A full byte
/// count is not a successful commit until the native completion event arrives.
class SyncTransferProgress extends StatelessWidget {
  const SyncTransferProgress({super.key, required this.event});
  final Map<String, dynamic> event;
  @override
  Widget build(BuildContext context) {
    final bytes = event['bytes'] as int;
    final total = event['total'] as int;
    final complete = event['complete'] == true;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${event['direction']} · ${event['path']}'),
      Text(
          '$bytes / $total bytes${complete ? ' · complete' : bytes == total ? ' · verifying / committing' : ''}'),
      LinearProgressIndicator(
          value: total > 0
              ? (bytes / total).clamp(0.0, 1.0)
              : complete
                  ? 1
                  : null),
    ]);
  }
}

class ConflictChoiceDialog extends StatelessWidget {
  const ConflictChoiceDialog(
      {super.key, required this.original, required this.copy});
  final String original;
  final String copy;
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Resolve conflict'),
        content: Text(
            'Mine (preserved local version): $copy\n\nTheirs (current canonical version): $original\n\n'
            'Keep mine replaces the canonical version and saves theirs as a synced .recovered- file. '
            'Keep theirs leaves the canonical version and archives mine as a synced .recovered- file. '
            'Keep both keeps theirs at the original path and mine as a synced .kept- file. '
            'Neither version is deleted. If either changed since sync, review is required again.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'mine'),
              child: const Text('Keep mine')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'theirs'),
              child: const Text('Keep theirs')),
          TextButton(
              onPressed: () => Navigator.pop(context, 'both'),
              child: const Text('Keep both')),
        ],
      );
}
