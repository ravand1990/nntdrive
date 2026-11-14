import 'dart:io';

import 'package:flutter/material.dart';

import 'local_availability.dart';

class LocalAvailabilityLabel extends StatelessWidget {
  const LocalAvailabilityLabel({super.key, required this.state, required this.details});
  final LocalAvailability state;
  final String details;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: state.displayExplanation,
        child: Text('$details · ${state.displayLabel}'),
      );
}

class LocalRevealButton extends StatelessWidget {
  const LocalRevealButton({super.key, required this.state, required this.onReveal});
  final LocalAvailability state;
  final VoidCallback onReveal;

  @override
  Widget build(BuildContext context) {
    final desktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final enabled = desktop && state.path != null;
    return IconButton(
      tooltip: !desktop
          ? 'Show in folder is only supported on desktop.'
          : enabled ? 'Show in folder'
              : 'Show in folder unavailable: ${state.displayExplanation}',
      icon: const Icon(Icons.folder_open_outlined),
      // Material 3 icon buttons default to a 40dp container; row actions must
      // stay a 48dp touch target.
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      onPressed: enabled ? onReveal : null,
    );
  }
}
