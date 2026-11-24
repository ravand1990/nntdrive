import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/browser_file_details.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/sync_controller.dart';

void main() {
  for (final width in [320.0, 600.0, 1024.0, 1440.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('details $width at $scale long name and dismissal', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final name = '${List.filled(180, 'x').join()} long name.txt';
        final file = RemoteFile(
          'opaque',
          null,
          '',
          false,
          123456789,
          true,
          1,
          'revision',
          updatedAt: DateTime.parse('2026-01-02T03:00:00+03:00'),
        );
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => BrowserFileDetails.observed(
                      file: file,
                      name: name,
                      availability: LocalAvailability.unknown,
                      pinned: false,
                    ),
                  ),
                  child: const Text('Inspect'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Inspect'));
        await tester.pumpAndSettle();
        expect(find.text(name), findsOneWidget);
        expect(find.text('123456789 bytes'), findsOneWidget);
        expect(find.text('2026-01-02T00:00:00.000Z'), findsOneWidget);
        expect(find.text('Unknown'), findsOneWidget);
        expect(
          find.text('No pin evidence (not pinned or cache unavailable)'),
          findsOneWidget,
        );
        expect(find.textContaining('Not last access'), findsOneWidget);
        expect(find.textContaining('may be stale'), findsOneWidget);
        expect(find.text('Synced'), findsNothing);
        final close = find.text('Close details');
        expect(
          tester
              .getSize(find.widgetWithText(TextButton, 'Close details'))
              .height,
          greaterThanOrEqualTo(48),
        );
        await tester.ensureVisible(find.textContaining('may be stale'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(close);
        await tester.pumpAndSettle();
        expect(find.byType(BrowserFileDetails), findsNothing);
        await tester.tap(find.text('Inspect'));
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(BrowserFileDetails), findsNothing);
        await tester.tap(find.text('Inspect'));
        await tester.pumpAndSettle();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(BrowserFileDetails), findsNothing);
        await tester.tap(find.text('Inspect'));
        await tester.pumpAndSettle();
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
        expect(find.byType(BrowserFileDetails), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'details freezes current evidence and separates folders and pins',
    (tester) async {
      final folder = SyncFolderConfig(
        id: 'sync',
        name: 'Sync',
        localPath: '/local',
        remoteRootId: 'root',
      );
      final local = LocalAvailability(
        'Local',
        'Disk presence only.',
        folder: folder,
        relativePath: 'item',
        verifiedAtRefresh: true,
      );
      final details = BrowserFileDetails.observed(
        file: RemoteFile('opaque', null, '', true, 999999, false, 1, null),
        name: 'Folder',
        availability: local,
        pinned: true,
      );
      folder.running = true;
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: details)));
      expect(
        find.text('Not calculated for folders (not an aggregate).'),
        findsOneWidget,
      );
      expect(find.text('999999 bytes'), findsNothing);
      expect(find.text('Not applicable to folders'), findsOneWidget);
      expect(find.text('Unknown'), findsOneWidget);
      expect(find.textContaining('freshly hashed local bytes'), findsOneWidget);
      expect(find.text('Syncing'), findsNothing);
    },
  );

  testWidgets('positive pin is independent from conflict evidence', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BrowserFileDetails.observed(
            file: RemoteFile(
              'opaque',
              null,
              '',
              false,
              0,
              false,
              1,
              'revision',
            ),
            name: 'Empty',
            availability: const LocalAvailability(
              'Conflict',
              'Review both copies.',
            ),
            pinned: true,
          ),
        ),
      ),
    );
    expect(find.text('0 bytes'), findsOneWidget);
    expect(find.text('Pin observed on this device'), findsOneWidget);
    expect(find.text('Conflict'), findsOneWidget);
    expect(find.text('Review both copies.'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);
  });
}
