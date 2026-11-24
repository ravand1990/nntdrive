import 'package:flutter/material.dart';

import 'api.dart';
import 'local_availability.dart';

/// A read-only observation supplied by FilesPage. No loaders or action adapters:
/// opening details cannot inspect disk, read content, or contact the server.
class BrowserFileDetails extends StatelessWidget {
  const BrowserFileDetails({
    super.key,
    required this.file,
    required this.name,
    required this.availabilityLabel,
    required this.availabilityExplanation,
    required this.pinned,
  });

  final RemoteFile file;
  final String name;
  // Freeze display evidence, not the mutable sync-folder object behind it.
  final String availabilityLabel;
  final String availabilityExplanation;
  final bool pinned;

  factory BrowserFileDetails.observed({
    required RemoteFile file,
    required String name,
    required LocalAvailability availability,
    required bool pinned,
  }) => BrowserFileDetails(
    file: file,
    name: name,
    availabilityLabel: availability.displayLabel,
    availabilityExplanation: availability.displayExplanation,
    pinned: pinned,
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    constraints: const BoxConstraints(maxWidth: 560),
    title: const Text('File details'),
    content: SizedBox(
      width: 512,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _field(context, 'Name', name),
            _field(context, 'Type', file.isDir ? 'Folder' : 'File'),
            _field(
              context,
              'Listed size',
              file.isDir
                  ? 'Not calculated for folders (not an aggregate).'
                  : file.size < 0
                  ? 'Unknown'
                  : '${file.size} bytes',
            ),
            const Text('Listing metadata, not verified manifest content size.'),
            _field(
              context,
              'Namespace modified (UTC)',
              file.updatedAt?.toUtc().toIso8601String() ?? 'Unknown',
            ),
            const Text(
              'May include rename or favorite changes. Not last access or verified content age.',
            ),
            _field(context, 'Favorite', file.favorite ? 'Yes' : 'No'),
            _field(context, 'Local / sync observation', availabilityLabel),
            Text(availabilityExplanation),
            _field(
              context,
              'Offline pin · listed revision',
              file.isDir
                  ? 'Not applicable to folders'
                  : pinned
                  ? 'Pin observed on this device'
                  : 'No pin evidence (not pinned or cache unavailable)',
            ),
            const Text(
              'A pin is not proof of current content equality or durability.',
            ),
            const SizedBox(height: 16),
            const Text(
              'Read-only snapshot from this browser listing and its existing device evidence; may be stale. Close and refresh to recheck. No content is downloaded or inspected by opening details.',
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close details'),
      ),
    ],
  );

  Widget _field(BuildContext context, String label, String value) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        SelectableText(value),
      ],
    ),
  );
}
