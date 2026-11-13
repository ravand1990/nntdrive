// In-context notice while browsing a space whose device is offline (#95).
//
// The spaces overview already marks each space, but writes happen in the
// library browser. A banner there says what a cross-device change means: the
// reconnecting device keeps both versions as a conflict copy instead of
// overwriting either one. This is disclosure only; it blocks nothing.

import 'package:flutter/material.dart';

import 'api.dart';

class SpaceWriteNotice extends StatelessWidget {
  const SpaceWriteNotice(
      {super.key, required this.root, required this.message});

  final AccountRoot root;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final revoked = root.deviceRevoked;
    return Container(
      key: const ValueKey('space-write-notice'),
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            revoked ? Icons.link_off : Icons.cloud_off_outlined,
            size: 18,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}
