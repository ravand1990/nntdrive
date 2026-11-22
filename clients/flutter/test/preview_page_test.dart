import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/preview.dart';
import 'package:nntdrive/preview_page.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  group('preview page', () {
    testWidgets('shows decrypted text with the local-only note', (
      tester,
    ) async {
      var downloads = 0;
      await tester.pumpWidget(
        _wrap(
          PreviewPage(
            title: 'notes.md',
            load: () async => PreviewContent.text('hello preview'),
            onDownload: () => downloads++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('notes.md'), findsOneWidget);
      expect(find.text('hello preview'), findsOneWidget);
      expect(
        find.textContaining('decrypted on this device only'),
        findsOneWidget,
      );

      await tester.tap(find.text('Download and open'));
      await tester.pumpAndSettle();
      expect(downloads, 1);
    });

    testWidgets('marks text that was cut short', (tester) async {
      await tester.pumpWidget(
        _wrap(
          PreviewPage(
            title: 'big.log',
            load: () async => PreviewContent.text(
              'first part',
              truncated: true,
              byteLength: 900000,
            ),
            onDownload: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('first part'), findsOneWidget);
      expect(find.textContaining('Only the first part'), findsOneWidget);
    });

    testWidgets(
      'explains an unsupported type and offers the download fallback',
      (tester) async {
        var downloads = 0;
        await tester.pumpWidget(
          _wrap(
            PreviewPage(
              title: 'report.pdf',
              load: () async =>
                  PreviewContent.unavailable(unsupportedPreviewMessage),
              onDownload: () => downloads++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text(unsupportedPreviewMessage), findsOneWidget);
        expect(find.textContaining('Download it to open it'), findsOneWidget);
        await tester.tap(find.text('Download and open'));
        await tester.pumpAndSettle();
        expect(downloads, 1);
      },
    );

    testWidgets('reports a load failure instead of an empty page', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          PreviewPage(
            title: 'notes.txt',
            load: () async =>
                throw StateError('the server refused the download'),
            onDownload: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be prepared'), findsOneWidget);
      expect(
        find.textContaining('the server refused the download'),
        findsOneWidget,
      );
    });

    testWidgets('decodes an image from memory', (tester) async {
      final png = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM'
        'IQAAAABJRU5ErkJggg==',
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          _wrap(
            PreviewPage(
              title: 'pixel.png',
              load: () async => PreviewContent.image(png),
              onDownload: () {},
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      expect(find.byType(Image), findsOneWidget);
      expect(find.textContaining('could not be shown'), findsNothing);
    });
  });
}
