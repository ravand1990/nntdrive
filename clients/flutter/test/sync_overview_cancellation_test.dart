import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:nntdrive/sync_overview_page.dart';

List<SyncFolderConfig> folders() => [
  for (var i = 0; i < 2; i++)
    SyncFolderConfig(
      id: '$i',
      name: 'Folder $i',
      localPath: '/unused/$i',
      remoteRootId: 'remote-$i',
    ),
];

void main() {
  test('pre-cancelled refresh admits no inspection or worker', () async {
    final cancellation = OverviewCancellation()..cancel();
    final result = buildUnsyncedOverview(
      folders: folders(),
      cancellation: cancellation,
      inspect: (_) async => fail('Cancelled refresh must not inspect'),
      mapFolder: (_, _, _, _) async => fail('Must not map'),
      orderEntries: (_) async => fail('Must not order'),
      projectEntries: (_) async => fail('Must not project'),
    );
    await expectLater(result, throwsA(isA<OverviewCancelled>()));
  });

  for (final stage in ['inspect', 'map', 'order', 'project']) {
    for (final failStage in [false, true]) {
      test('cancellation awaits admitted $stage (failure=$failStage)', () async {
        final cancellation = OverviewCancellation();
        final entered = Completer<void>();
        final release = Completer<void>();
        final calls = <String>[];
        var settled = false;
        Future<void> gate(String current) async {
          calls.add(current);
          if (current != stage) return;
          entered.complete();
          await release.future;
          if (failStage) throw StateError('private stage diagnostic');
        }

        final result = buildUnsyncedOverview(
          folders: folders(),
          cancellation: cancellation,
          inspect: (folder) async {
            await gate('inspect');
            return {'items': <Object>[]};
          },
          mapFolder: (folder, plan, budget, failed) async {
            await gate('map');
            return mapUnsyncedFolder(folder, plan, budget, failed);
          },
          orderEntries: (entries) async {
            await gate('order');
            return entries;
          },
          projectEntries: (entries) async {
            await gate('project');
            return projectUnsyncedEntries(entries);
          },
        );
        // Attach before cancellation/error so no asynchronous error is unhandled.
        final checked = expectLater(result, throwsA(isA<OverviewCancelled>()));
        unawaited(
          result.then<void>(
            (_) => settled = true,
            onError: (Object _, StackTrace _) {
              settled = true;
            },
          ),
        );
        await entered.future.timeout(const Duration(seconds: 5));
        final admittedCalls = List<String>.of(calls);
        cancellation.cancel();
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse, reason: 'An admitted stage must be awaited');
        expect(calls, admittedCalls);
        release.complete();
        await checked;
        expect(calls, admittedCalls, reason: 'No later stage may be admitted');
      });
    }
  }

  test('uncancelled refresh retains ordinary folder failure notices', () async {
    final result = await buildUnsyncedOverview(
      folders: folders(),
      cancellation: OverviewCancellation(),
      inspect: (_) async => throw StateError('private filesystem diagnostic'),
    );
    expect(result.notices, hasLength(2));
    expect(
      result.notices.every((notice) => !notice.message.contains('private')),
      isTrue,
    );
  });

  testWidgets('later refresh owns a fresh cancellation token', (tester) async {
    final tokens = <OverviewCancellation>[];
    final release = Completer<UnsyncedOverview>();
    final empty = UnsyncedOverview(
      entries: const [],
      folders: const [],
      notices: const [],
      inspectedAt: DateTime(2026),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SyncOverviewPage(
          load: (token) {
            tokens.add(token);
            return tokens.length == 1 ? Future.value(empty) : release.future;
          },
          onSyncFolder: (_) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Check again'));
    await tester.pump();
    expect(tokens, hasLength(2));
    expect(identical(tokens.first, tokens.last), isFalse);
    expect(tokens.last.isCancelled, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tokens.last.isCancelled, isTrue);
    expect(tokens.first.isCancelled, isFalse);
    release.complete(empty);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final failInspection in [false, true]) {
    testWidgets(
      'page disposal cancels the production builder ($failInspection)',
      (tester) async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final finished = Completer<void>();
        final calls = <String>[];
        late OverviewCancellation cancellation;
        await tester.pumpWidget(
          MaterialApp(
            home: SyncOverviewPage(
              load: (token) async {
                cancellation = token;
                try {
                  return await buildUnsyncedOverview(
                    folders: folders(),
                    cancellation: token,
                    inspect: (folder) async {
                      calls.add(folder.id);
                      if (!entered.isCompleted) entered.complete();
                      await release.future;
                      if (failInspection) {
                        throw StateError('private diagnostic');
                      }
                      return {'items': <Object>[]};
                    },
                  );
                } finally {
                  finished.complete();
                }
              },
              onSyncFolder: (_) async {},
            ),
          ),
        );
        expect(entered.isCompleted, isTrue);
        expect(calls, ['0']);
        await tester.pumpWidget(const SizedBox.shrink());
        final cancelledOnDispose = cancellation.isCancelled;
        final awaitedOnDispose = !finished.isCompleted;
        release.complete();
        await tester.runAsync(() async {
          await finished.future.timeout(const Duration(seconds: 5));
        });
        await tester.pump();
        expect(cancelledOnDispose, isTrue);
        expect(awaitedOnDispose, isTrue);
        expect(calls, ['0'], reason: 'Second folder must not be scanned');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
