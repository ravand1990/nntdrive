import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:nntdrive/sync_overview_page.dart';

UnsyncedOverview snapshot(String path) => UnsyncedOverview(
  entries: [
    UnsyncedEntry(
      status: UnsyncedStatus.localOnly,
      folderId: 'f',
      folderName: 'Documents',
      path: path,
      reason: 'Not uploaded yet.',
    ),
  ],
  folders: const [],
  notices: const [],
  inspectedAt: DateTime(2026),
);

void main() {
  for (final failFirst in [false, true]) {
    testWidgets(
      'coalesces notifications during a suspended load ($failFirst)',
      (tester) async {
        final changes = ChangeNotifier();
        final pending = <Completer<UnsyncedOverview>>[];
        var active = 0;
        var peak = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: SyncOverviewPage(
              load: () async {
                active++;
                if (active > peak) peak = active;
                final result = Completer<UnsyncedOverview>();
                pending.add(result);
                try {
                  return await result.future;
                } finally {
                  active--;
                }
              },
              onSyncFolder: (_) async {},
              watch: changes,
            ),
          ),
        );
        for (var i = 0; i < 4; i++) {
          changes.notifyListeners();
          await tester.pump(const Duration(milliseconds: 400));
        }
        // Inspectors may include a native scan and must never overlap.
        expect(pending, hasLength(1));
        expect(peak, 1);
        if (failFirst) {
          pending.first.completeError(StateError('private diagnostic'));
        } else {
          pending.first.complete(snapshot('stale.txt'));
        }
        await tester.pump();
        expect(pending, hasLength(2));
        expect(find.text('stale.txt'), findsNothing);
        expect(find.textContaining('could not be checked'), findsNothing);
        changes.notifyListeners();
        await tester.pump(const Duration(milliseconds: 400));
        expect(pending, hasLength(2));
        pending.last.complete(snapshot('also-stale.txt'));
        await tester.pump();
        expect(pending, hasLength(3));
        expect(find.text('also-stale.txt'), findsNothing);
        pending.last.complete(snapshot('fresh.txt'));
        await tester.pumpAndSettle();
        expect(find.text('fresh.txt'), findsOneWidget);
        expect(peak, 1);
        await tester.pump(const Duration(seconds: 1));
        expect(pending, hasLength(3));
        await tester.pumpWidget(const SizedBox.shrink());
        changes.dispose();
      },
    );
  }

  testWidgets('disposal drops queued refresh and late results', (tester) async {
    final changes = ChangeNotifier();
    final pending = Completer<UnsyncedOverview>();
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SyncOverviewPage(
          load: () {
            loads++;
            return pending.future;
          },
          onSyncFolder: (_) async {},
          watch: changes,
        ),
      ),
    );
    changes.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(snapshot('late.txt'));
    await tester.pump(const Duration(seconds: 1));
    expect(loads, 1);
    expect(tester.takeException(), isNull);
    changes.dispose();
  });

  testWidgets('manual refresh consumes a pending notification timer', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SyncOverviewPage(
          load: () async => snapshot('file-${++loads}.txt'),
          onSyncFolder: (_) async {},
          watch: changes,
        ),
      ),
    );
    await tester.pumpAndSettle();
    changes.notifyListeners();
    await tester.tap(find.byTooltip('Check again'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
    expect(loads, 2);
    expect(find.text('file-2.txt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
  });

  for (final useAction in [false, true]) {
    testWidgets('queued automatic load waits for idle (action=$useAction)', (
      tester,
    ) async {
      final changes = ChangeNotifier();
      final pending = Completer<UnsyncedOverview>();
      final action = Completer<void>();
      var loads = 0;
      var busy = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncOverviewPage(
            load: () {
              loads++;
              return loads == 2
                  ? pending.future
                  : Future.value(snapshot('file-$loads.txt'));
            },
            onSyncFolder: (_) => action.future,
            watch: changes,
            isBusy: () => busy,
          ),
        ),
      );
      await tester.pumpAndSettle();
      changes.notifyListeners();
      await tester.pump(const Duration(milliseconds: 400));
      expect(loads, 2);
      changes.notifyListeners(); // Queued before action/sync admission changes.
      if (useAction) {
        await tester.tap(find.byTooltip('Sync Documents now'));
        await tester.pump();
      } else {
        busy = true;
      }
      pending.complete(snapshot('old.txt'));
      await tester.pump();
      expect(loads, 2, reason: 'automatic follow-up must recheck admission');
      if (useAction) {
        action.complete(); // Completion owns the next explicit refresh.
      } else {
        busy = false;
        changes.notifyListeners();
      }
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(loads, 3);
      expect(find.text('file-3.txt'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      changes.dispose();
    });
  }

  testWidgets('debounced notification rechecks whether sync started', (
    tester,
  ) async {
    final changes = ChangeNotifier();
    var busy = false;
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SyncOverviewPage(
          load: () async => snapshot('file-${++loads}.txt'),
          onSyncFolder: (_) async {},
          watch: changes,
          isBusy: () => busy,
        ),
      ),
    );
    await tester.pumpAndSettle();
    changes.notifyListeners();
    busy = true;
    await tester.pump(const Duration(milliseconds: 400));
    expect(loads, 1);
    busy = false;
    changes.notifyListeners();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(loads, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    changes.dispose();
  });
}
