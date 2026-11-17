import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

/// A release heading stays outside Markdown so release text cannot spoof it.
class ReleaseNotesSection {
  const ReleaseNotesSection(this.version, this.body);

  final String version;
  final String body;
}

/// Shared desktop/Android notes viewport. Empty notes occupy no space.
class ReleaseNotesView extends StatelessWidget {
  const ReleaseNotesView({
    super.key,
    this.notes = '',
    this.releases = const [],
    this.olderNotesOmitted = 0,
    this.maxHeight = 320,
  });

  final String notes;
  final List<ReleaseNotesSection> releases;
  final int olderNotesOmitted;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    if (releases.isEmpty && notes.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: SingleChildScrollView(
        primary: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: releases.isEmpty
              ? [ReleaseNotesMarkdown(data: notes)]
              : [
                  for (var i = 0; i < releases.length; i++) ...[
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : 16),
                      child: SelectableText(
                        'Changes in ${releases[i].version}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ReleaseNotesMarkdown(data: releases[i].body),
                  ],
                  if (olderNotesOmitted > 0) ...[
                    const SizedBox(height: 16),
                    SelectableText(
                      '$olderNotesOmitted older release'
                      '${olderNotesOmitted == 1 ? '' : 's'} not shown.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
        ),
      ),
    );
  }
}

/// Fail closed before reaching a platform URL handler. No relative URLs,
/// credentials, whitespace/control characters, backslashes or broken escapes.
Uri? releaseNotesLink(String? href) {
  if (href == null ||
      RegExp(r'[\s\x00-\x20\x7f\\]').hasMatch(href) ||
      RegExp(r'%(?![0-9a-fA-F]{2})').hasMatch(href) ||
      RegExp(r'%(?:0[0-9a-f]|1[0-9a-f]|7f)', caseSensitive: false)
          .hasMatch(href)) {
    return null;
  }
  try {
    final uri = Uri.parse(href);
    if (uri.scheme != 'https' ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.port < 1 ||
        uri.port > 65535) {
      return null;
    }
    final host = uri.host;
    final dns = host.length <= 253 &&
        host.split('.').every((label) => RegExp(
              r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
            ).hasMatch(label));
    if (!dns && InternetAddress.tryParse(host) == null) return null;
    return uri;
  } on FormatException {
    return null;
  }
}

/// The maintained parser and widget builder run in one guarded boundary rather
/// than a child MarkdownBody lifecycle (whose parse failures cannot be caught
/// by its parent). No HTML engine or image provider is ever created.
class ReleaseNotesMarkdown extends StatefulWidget {
  const ReleaseNotesMarkdown({super.key, required this.data, this.parser});

  final String data;

  /// Injection seam for deterministic parser-failure regression tests.
  @visibleForTesting
  final List<md.Node> Function(String)? parser;

  @override
  State<ReleaseNotesMarkdown> createState() => _ReleaseNotesMarkdownState();
}

class _ReleaseNotesMarkdownState extends State<ReleaseNotesMarkdown>
    implements MarkdownBuilderDelegate {
  final _recognizers = <TapGestureRecognizer>[];

  void _disposeRecognizers() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  Future<void> _openLink(String? href) async {
    final uri = releaseNotesLink(href);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      // An absent browser/plugin must not interrupt the update prompt.
    }
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final recognizer = TapGestureRecognizer();
    if (releaseNotesLink(href) != null) {
      recognizer.onTap = () => _openLink(href);
    }
    _recognizers.add(recognizer);
    return recognizer;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) => TextSpan(
        style: styleSheet.code,
        text: code.replaceFirst(RegExp(r'\n$'), ''),
      );

  // Remove image nodes before the builder sees them, including reference,
  // nested, local and data images. Keep alt text readable and selectable.
  List<md.Node> _withoutImages(List<md.Node> nodes) => [
        for (final node in nodes)
          if (node is md.Element && node.tag == 'img')
            md.Text(node.attributes['alt'] ?? '')
          else if (node is md.Element)
            md.Element(node.tag, _withoutImages(node.children ?? []))
              ..attributes.addAll(node.attributes)
          else
            node,
      ];

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    try {
      final nodes = widget.parser?.call(widget.data) ??
          md.Document(
            extensionSet: md.ExtensionSet.commonMark,
            encodeHtml: false,
          ).parseLines(const LineSplitter().convert(widget.data));
      final styles = MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: Theme.of(context).textTheme.bodySmall,
        code: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontFamily: 'monospace',
              backgroundColor: Theme.of(context).colorScheme.surfaceContainer,
            ),
      );
      final children = MarkdownBuilder(
        delegate: this,
        selectable: true,
        styleSheet: styles,
        imageDirectory: null,
        imageBuilder: (_, __, alt) => SelectableText(alt ?? ''),
        checkboxBuilder: null,
        bulletBuilder: null,
        builders: const {},
        paddingBuilders: const {},
        listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
        contextMenuBuilder: (context, state) =>
            AdaptiveTextSelectionToolbar.editableText(editableTextState: state),
      ).build([
        for (final node in _withoutImages(nodes))
          // CommonMark emits raw HTML blocks as top-level Text nodes; the
          // widget builder expects blocks. Preserve them as literal text.
          if (node is md.Text) md.Element('p', [node]) else node,
      ]);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      );
    } catch (_) {
      _disposeRecognizers();
      return SelectableText(
        widget.data,
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
  }
}
