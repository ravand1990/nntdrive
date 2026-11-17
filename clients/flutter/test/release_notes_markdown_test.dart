import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/android_update.dart';
import 'package:nntdrive/android_update_prompt.dart';
import 'package:nntdrive/release_notes.dart';
import 'package:nntdrive/update_prompt.dart';
import 'package:nntdrive/updater.dart';
import 'package:shared_preferences/shared_preferences.dart';

const sample = '''## Changes

### Features

A **bold** and *italic* paragraph with `inline_code`.

- First bullet
- Second bullet

1. First numbered
2. Second numbered

> Quoted release guidance

---

```sh
nntdrive --version
```

[Release page](https://example.invalid/releases)
''';

UpdateInfo offer(String body, {List<ReleaseNote> releases = const []}) =>
    UpdateInfo(
      version: '9.0.0',
      notes: body,
      releaseNotes: releases,
      assetName: 'test',
      assetUrl: Uri.parse('https://example.invalid/test'),
      size: 1,
    );

Future<void> pump(WidgetTester tester, Widget child,
    {double scale = 1, Brightness brightness = Brightness.light}) async {
  await tester.pumpWidget(MaterialApp(
    theme: ThemeData(brightness: brightness),
    builder: (context, child) => MediaQuery(
      data:
          MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
        body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 360,
              child: child,
            ))),
  ));
  await tester.pumpAndSettle();
}

Iterable<TextSpan> spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* spans(child);
    }
  }
}

Iterable<TextSpan> allSpans(WidgetTester tester) sync* {
  for (final text
      in tester.widgetList<SelectableText>(find.byType(SelectableText))) {
    if (text.textSpan != null) yield* spans(text.textSpan!);
  }
}

class DeferredAndroidUpdater extends AndroidUpdater {
  DeferredAndroidUpdater()
      : super(config: const UpdateConfig(repo: 'example/test', token: ''));

  @override
  Future<void> defer(AndroidUpdateInfo info) async {}
}

void main() {
  testWidgets('published v0.27.8 release body renders without raw Markdown',
      (tester) async {
    // Verbatim public release: https://github.com/ravand1990/nntdrive/releases/tag/v0.27.8
    final body = File('test/fixtures/release-v0.27.8.md').readAsStringSync();
    await pump(tester, UpdateNotesView(info: offer(body)));
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Bug fixes'), findsOneWidget);
    expect(find.text(body), findsNothing);
    expect(
        allSpans(tester).any((s) =>
            s.text == 'Not synced' && s.style?.fontWeight == FontWeight.bold),
        isTrue);
    expect(
        allSpans(tester).any((s) =>
            s.text == 'ghcr.io/ravand1990/nntdrive-backend:0.27.8' &&
            s.style?.fontFamily == 'monospace'),
        isTrue);
    expect(tester.takeException(), isNull);
  });

  test('HTTPS URI validation is fail closed', () {
    for (final value in [
      null,
      '',
      'javascript:alert(1)',
      'file:///etc/passwd',
      'data:text/plain,x',
      'http://example.invalid',
      '/relative',
      '//example.invalid/path',
      '#fragment',
      'https:',
      'https:///path',
      'https://',
      'https://user:password@example.invalid',
      'https://bad host/path',
      'https://example.invalid\\@evil.invalid',
      ' https://example.invalid',
      'https://example.invalid/\npath',
      'https://example.invalid/%0a',
      'https://example.invalid/%7F',
      'https://example.invalid/%zz',
      'https://example.invalid:bad',
      'https://example.invalid:65536',
      'https://example.invalid:0',
      'https://-bad.invalid',
    ]) {
      expect(releaseNotesLink(value), isNull, reason: '$value');
    }
    for (final value in [
      'https://example.invalid/releases?q=a%20b#notes',
      'https://example.invalid:8443/path',
      'https://127.0.0.1/path',
    ]) {
      expect(releaseNotesLink(value)?.toString(), value);
    }
  });

  testWidgets('desktop renders headings, lists, emphasis, code, quote and rule',
      (tester) async {
    await pump(tester, UpdateNotesView(info: offer(sample)));
    expect(find.text(sample), findsNothing);
    expect(find.text('Changes'), findsOneWidget);
    expect(find.text('Features'), findsOneWidget);
    expect(find.text('First bullet'), findsOneWidget);
    expect(find.text('Second numbered'), findsOneWidget);
    expect(find.text('Quoted release guidance'), findsOneWidget);
    final rendered = allSpans(tester).toList();
    expect(
        rendered.any(
            (s) => s.text == 'bold' && s.style?.fontWeight == FontWeight.bold),
        isTrue);
    expect(
        rendered.any((s) =>
            s.text == 'italic' && s.style?.fontStyle == FontStyle.italic),
        isTrue);
    expect(
        rendered.any((s) =>
            s.text == 'inline_code' && s.style?.fontFamily == 'monospace'),
        isTrue);
    expect(
        rendered.any((s) =>
            s.text == 'nntdrive --version' &&
            s.style?.fontFamily == 'monospace'),
        isTrue);
    final heading = rendered.firstWhere((s) => s.text == 'Changes');
    final paragraph = rendered.firstWhere((s) => s.text == 'First bullet');
    expect(heading.style!.fontSize, greaterThan(paragraph.style!.fontSize!));
    expect(find.text('•'), findsNWidgets(2));
    expect(find.text('1.'), findsOneWidget);
    expect(find.text('2.'), findsOneWidget);
    expect(
        find.byWidgetPredicate((w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).border is Border &&
            ((w.decoration! as BoxDecoration).border! as Border).top.width > 0),
        findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('aggregated bodies use Markdown and preserve version boundaries',
      (tester) async {
    await pump(
        tester,
        UpdateNotesView(
            info: offer('ignored', releases: const [
          ReleaseNote(version: '9.0.0', body: '## Newest\n\n- Item'),
          ReleaseNote(version: '8.0.0', body: '**Older**'),
          ReleaseNote(version: '7.0.0', body: ''),
        ])));
    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    expect(find.text('ignored'), findsNothing);
    expect(tester.getTopLeft(find.text('Changes in 9.0.0')).dy,
        lessThan(tester.getTopLeft(find.text('Changes in 8.0.0')).dy));
    expect(find.text('Changes in 7.0.0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'parser failure falls back to exact selectable plain text and recovers',
      (tester) async {
    await pump(
        tester,
        ReleaseNotesMarkdown(
          data: sample,
          parser: (_) =>
              throw const FormatException('deliberate parse failure'),
        ));
    expect(find.text(sample), findsOneWidget);
    expect(
        tester
            .widget<SelectableText>(find.ancestor(
                of: find.text(sample), matching: find.byType(SelectableText)))
            .data,
        sample);
    expect(tester.takeException(), isNull);
    await pump(tester, const ReleaseNotesMarkdown(data: '## Recovered'));
    expect(find.text('Recovered'), findsOneWidget);
    expect(find.text(sample), findsNothing);
  });

  testWidgets('unsupported and unfinished Markdown stays readable',
      (tester) async {
    const data =
        'Unclosed **emphasis and [broken](\n\n<table>unsupported</table>';
    await pump(tester, const ReleaseNotesView(notes: data));
    expect(find.textContaining('Unclosed **emphasis'), findsOneWidget);
    expect(find.textContaining('<table>unsupported</table>'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('HTML is literal and all image forms are inert alt text',
      (tester) async {
    const data = '''<script>alert('not run')</script>

<img src="https://tracking.invalid/pixel" onerror="alert(1)">

<iframe src="https://tracking.invalid/frame"></iframe>

![Remote alt](https://tracking.invalid/image.png)
![Local alt](file:///etc/passwd)
![Data alt](data:image/png;base64,AAAA)
![Reference alt][pixel]

[pixel]: https://tracking.invalid/pixel
''';
    await pump(tester, const ReleaseNotesView(notes: data));
    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('<script>'), findsOneWidget);
    expect(find.textContaining('<img src='), findsOneWidget);
    expect(find.textContaining('<iframe'), findsOneWidget);
    for (final text in [
      'Remote alt',
      'Local alt',
      'Data alt',
      'Reference alt'
    ]) {
      expect(find.textContaining(text), findsWidgets);
    }
    expect(allSpans(tester).where((s) => s.recognizer != null), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'only HTTPS links reach external platform handler, errors are contained',
      (tester) async {
    final calls = <MethodCall>[];
    var fail = false;
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel,
        (call) async {
      calls.add(call);
      if (fail) throw PlatformException(code: 'no-browser');
      return true;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    await pump(
        tester,
        const ReleaseNotesView(
            notes: '''[Safe](https://example.invalid/releases)

[JS](javascript:alert%281%29) [File](file:///etc/passwd) [Relative](/relative) [HTTP](http://example.invalid) [Bad](https://bad%20host/)
'''));
    await tester.tap(find.text('Safe'));
    await tester.pump();
    expect(calls, hasLength(1));
    expect(calls.single.method, 'launch');
    expect(calls.single.arguments['url'], 'https://example.invalid/releases');
    expect(calls.single.arguments['useWebView'], isFalse);
    expect(calls.single.arguments['useSafariVC'], isFalse);
    final links = allSpans(tester)
        .where((s) => s.recognizer is TapGestureRecognizer)
        .toList();
    expect(links, hasLength(6));
    for (final span in links.where((s) => s.text != 'Safe')) {
      (span.recognizer! as TapGestureRecognizer).onTap?.call();
    }
    await tester.pump();
    expect(calls, hasLength(1));
    fail = true;
    (links.first.recognizer! as TapGestureRecognizer).onTap!();
    await tester.pump();
    expect(calls, hasLength(2));
    expect(tester.takeException(), isNull);
    await pump(tester, const ReleaseNotesView(notes: '## Rebuilt'));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'long notes are bounded, selectable and scroll at 200% ${brightness.name}',
        (tester) async {
      final body =
          '$sample\n${'Long paragraph with selectable text.\n\n' * 40}\nEnd marker';
      await pump(tester, ReleaseNotesView(notes: body),
          scale: 2, brightness: brightness);
      final viewport = find
          .descendant(
              of: find.byType(ReleaseNotesView),
              matching: find.byType(SingleChildScrollView))
          .first;
      expect(tester.getSize(viewport).height, lessThanOrEqualTo(320));
      final scroll = tester.state<ScrollableState>(find
          .descendant(of: viewport, matching: find.byType(Scrollable))
          .first);
      expect(scroll.position.maxScrollExtent, greaterThan(320));
      expect(
          MediaQuery.textScalerOf(tester.element(find.text('Changes')))
              .scale(12),
          24);
      await tester.longPress(find.text('Changes'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsWidgets);
      scroll.position.jumpTo(scroll.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('End marker').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final android in [false, true]) {
    for (final body in ['', sample, '$sample\n${'Long notes\n\n' * 50}']) {
      testWidgets(
          '${android ? 'Android' : 'desktop'} actual prompt at 200%, notes length ${body.length}',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        await tester.binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        late BuildContext context;
        await pump(tester, Builder(builder: (value) {
          context = value;
          return const SizedBox.shrink();
        }), scale: 2);
        final future = android
            ? promptAndroidUpdate(
                context,
                DeferredAndroidUpdater(),
                AndroidUpdateInfo(
                    version: '9.0.0',
                    versionCode: 900,
                    notes: body,
                    assetName: 'test.apk',
                    assetUrl: Uri.parse('https://example.invalid/test'),
                    size: 1,
                    sha256: '0' * 64),
                '1 B')
            : promptUpdate(context, offer(body), '1 B');
        await tester.pumpAndSettle();
        expect(find.text('Update available — 9.0.0'), findsOneWidget);
        if (body.isNotEmpty) {
          expect(find.byType(ReleaseNotesView), findsOneWidget);
          expect(find.text('Changes'), findsOneWidget);
          final viewport = find
              .descendant(
                  of: find.byType(ReleaseNotesView),
                  matching: find.byType(SingleChildScrollView))
              .first;
          expect(tester.getSize(viewport).height, lessThanOrEqualTo(320));
        } else {
          expect(find.byType(ReleaseNotesView), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Later'));
        await tester.pumpAndSettle();
        await tester.runAsync(() async => expect(await future, isTrue));
      });
    }
  }
}
