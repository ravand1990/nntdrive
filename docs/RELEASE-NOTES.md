# Update-prompt release notes (#154)

Windows/Linux and Android update prompts use the same `ReleaseNotesView` in
`clients/flutter/lib/release_notes.dart`. Desktop aggregation/version headings,
omitted-release counts, feed collection and prompt scheduling are unchanged.
Android shows its offered release body through that same bounded viewport.

## Rendering and security policy

- CommonMark headings, paragraphs, ordered/unordered lists, bold/italic, inline
  and fenced code, blockquotes, horizontal rules and links render as native
  Flutter widgets. No WebView or HTML engine is used. Unsupported/incomplete
  syntax remains readable text; tables/task lists are not promised.
- The entire notes history is vertically scrollable with a **320 logical-pixel
  maximum height** (and can shrink further to fit its parent). Fenced code has
  its own horizontal scroll. Text, code, version headings and omitted counts are
  selectable with the platform-adaptive selection toolbar. Text scaling is not
  capped; light/dark theme text styles are inherited.
- Raw HTML is literal text, never interpreted. Markdown image nodes (including
  reference, local and data images) become alt text **before** widget creation.
  An inert image builder is a second guard; no image provider is constructed,
  preventing tracking pixels and local-file reads.
- Links launch only on an explicit tap, using `url_launcher` with
  `LaunchMode.externalApplication`. Validation rejects non-HTTPS, relative,
  authority-less, empty/invalid-host, credential-bearing, invalid-port,
  whitespace/control/backslash and broken-percent-escape URLs. Encoded control
  characters are rejected too. The same validation runs at link creation and
  immediately before launch. Browser/plugin failures do not break the prompt.
  HTTPS is a transport/scheme policy, not a guarantee that a linked site is safe;
  the external browser owns any subsequent navigation/redirects.
- Parser and synchronous widget-builder failures fall back to the exact original
  body as selectable plain text, inside the same viewport. Errors are not logged
  with release content. This does not catch unrelated Flutter layout failures.

## Dependencies and maintenance review

The pub.dev package APIs and source were inspected for this change:

- [`flutter_markdown_plus` 1.0.12](https://pub.dev/packages/flutter_markdown_plus),
  published 2026-07-10, maintained at
  [foresightmobile/flutter_markdown_plus](https://github.com/foresightmobile/flutter_markdown_plus),
  provides native widgets, selectable rich text, code scrolling and adaptive
  styling. This maintained continuation is used instead of the older
  `flutter_markdown` package. Its exported `MarkdownBuilder` and
  `MarkdownBuilderDelegate` let parsing and widget generation share a catch
  boundary: wrapping a `MarkdownBody` child alone cannot catch parsing in that
  child's lifecycle. The adapter owns and disposes link gesture recognizers.
- [`markdown` 7.3.1](https://pub.dev/packages/markdown), published 2026-03-18,
  is maintained in dart-lang/tools. It is a direct dependency because the adapter
  parses its AST and removes images before passing nodes to the widget builder.
- [`url_launcher` 6.3.3](https://pub.dev/packages/url_launcher), published
  2026-10-02, is maintained in flutter/packages. External-application mode is
  explicit; no embedded browser or script execution mode is requested.

The lockfile records resolved versions/checksums and generated Linux/Windows
plugin registrants include the launcher. The Markdown renderer requires at least
Dart 3.11 / Flutter 3.41; the complete resolved lockfile requires Dart 3.13 /
Flutter 3.47. Checks retain the repository's pinned Flutter 3.47.9 /
Dart 3.13.7 container. Dependency resolution uses the wrapper's **networked
fetch stage**, not a host SDK or the offline check service.

## Verification and limitations

`test/release_notes_markdown_test.dart` covers the public v0.27.8 release body
(verbatim fixture with attribution in the test), all supported syntax,
aggregation/empty bodies, malformed syntax, deterministic parser failure and
recovery, HTML/images, URL validation, actual HTTPS taps/external-mode platform
arguments, rejected link taps and platform failure containment. It also covers
selection via the Copy toolbar, scrolling and 200% text scaling in both themes,
and actual desktop/Android dialogs at 200% with empty, single and long notes.
Existing update-note aggregation/omission tests continue to apply.

Regression validation temporarily restores the original plain-text prompts and
separately removes the HTTPS guard and parser fallback; the focused tests must
fail, after which all original production safeguards are restored. Run checks
with `bash scripts/dev-check.sh flutter` and capture the script's real exit code
by redirecting output to a log (not through an unguarded pipeline).

Widget/platform-channel tests do not establish an installed external-browser
launch, native Windows/Linux/Android visual appearance, Android PackageInstaller
behavior or a real update installation. Those manual platform passes remain
unverified; no deployment or release-note edits are part of this change.
