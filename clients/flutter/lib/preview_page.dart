import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'preview.dart';

/// The full-screen in-app preview for one file.
///
/// Preview bytes are decrypted on this device and only ever live in memory or
/// in the loader's short-lived scratch file; nothing is uploaded and no copy is
/// kept after the page closes.
class PreviewPage extends StatefulWidget {
  const PreviewPage({
    super.key,
    required this.title,
    required this.load,
    required this.onDownload,
  });

  final String title;

  /// Loads the bounded preview; called once when the page opens.
  final Future<PreviewContent> Function() load;

  /// The download-and-open fallback for unsupported or unreadable files.
  final VoidCallback onDownload;

  @override
  State<PreviewPage> createState() => _PreviewPageState();
}

class _PreviewPageState extends State<PreviewPage> {
  late Future<PreviewContent> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: FutureBuilder<PreviewContent>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('Decrypting on this device'),
                        ],
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return _Fallback(
                      icon: Icons.error_outline,
                      message: _errorMessage(snapshot.error),
                    );
                  }
                  return _content(context, snapshot.data!);
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Previews are decrypted on this device only; '
                    'no copy is uploaded or kept after you close this page.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.onDownload,
                          icon: const Icon(Icons.download),
                          label: const Text('Download and open'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(BuildContext context, PreviewContent content) {
    switch (content.kind) {
      case PreviewKind.image:
        return _image(context, content.imageBytes!);
      case PreviewKind.text:
        return _text(context, content);
      case PreviewKind.unsupported:
        return _Fallback(
          icon: Icons.visibility_off_outlined,
          message: content.message ?? unsupportedPreviewMessage,
        );
    }
  }

  Widget _image(BuildContext context, Uint8List bytes) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 8,
      child: Center(
        child: Image.memory(
          bytes,
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => const _Fallback(
            icon: Icons.broken_image_outlined,
            message:
                'This image could not be shown. It may be corrupt or use a '
                'format the app does not decode.',
          ),
        ),
      ),
    );
  }

  Widget _text(BuildContext context, PreviewContent content) {
    final theme = Theme.of(context);
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SelectableText(
              content.text ?? '',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier New', 'monospace'],
              ),
            ),
            if (content.truncated) ...[
              const SizedBox(height: 16),
              Text(
                'Only the first part of this file is shown. '
                'Download it to read the rest.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _errorMessage(Object? error) {
    final text = error?.toString().trim() ?? '';
    if (text.isEmpty) return 'This file could not be prepared for a preview.';
    return 'This file could not be prepared for a preview: $text';
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Download it to open it in the app for that file type.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
