import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';
import 'package:nntdrive/sync_overview_page.dart';

SyncFolderConfig folder(String id) =>
    SyncFolderConfig(id: id, name: id, localPath: '/unused', remoteRootId: id);

void main() {
  test(
    'all 20k+ rows are published exactly once with bounded worker inputs',
    () async {
      final config = folder('a')
        ..excluded = List.generate(513, (i) => 'excluded-$i');
      final token = OverviewCancellation();
      final publications = <UnsyncedOverview>[];
      token.onPublication = publications.add;
      var mappedRows = 0;
      var orderedRows = 0;
      var projectedRows = 0;
      final result = await buildIncrementalUnsyncedOverview(
        folders: [config, folder('b')],
        cancellation: token,
        mapFolder: (f, p, cap, failed) {
          expect(cap, 256);
          expect(f.excluded.length, lessThanOrEqualTo(256));
          return mapUnsyncedFolder(f, p, cap, failed).then((mapped) {
            expect(mapped.entries.length, lessThanOrEqualTo(256));
            mappedRows += mapped.entries.length;
            return mapped;
          });
        },
        orderEntries: (rows) {
          orderedRows += rows.length;
          return orderUnsyncedEntries(rows);
        },
        projectEntries: (rows) {
          projectedRows += rows.length;
          return projectUnsyncedEntries(rows);
        },
        inspectPages: (f, consume, keepGoing) async {
          final count = f.id == 'a' ? 20017 : 3;
          for (var start = 0; start < count; start += 256) {
            expect(keepGoing(), isTrue);
            final end = start + 256 < count ? start + 256 : count;
            await consume({
              'items': [
                for (var i = start; i < end; i++)
                  {'kind': 'upload', 'path': 'file-$i'},
              ],
              'done': end == count,
            });
            expect(publications.last.complete, isFalse);
            expect(publications.last.total, greaterThan(0));
          }
        },
      );
      expect(result.total, 20533);
      expect(mappedRows, result.total);
      expect(
        orderedRows,
        result.total,
        reason: 'never reorder accumulated rows',
      );
      expect(
        projectedRows,
        result.total,
        reason: 'never reproject accumulated rows',
      );
      expect(
        result.entries.map((e) => '${e.folderId}/${e.path}').toSet().length,
        result.total,
      );
      expect(result.counts, {
        UnsyncedStatus.localOnly: 20020,
        UnsyncedStatus.skipped: 513,
      });
      expect(
        result.filtered(folderId: 'a', status: UnsyncedStatus.localOnly).length,
        20017,
      );
      expect(result.filtered(folderId: 'b').length, 3);
      expect(result.folders.map((f) => f.total), [20530, 3]);
      expect(result.complete, isTrue);
      expect(result.truncated, isFalse);
      expect(
        publications.first.total,
        256,
        reason: 'old publications must stay immutable',
      );
      expect(publications.first.complete, isFalse);
      expect(() => result.entries.clear(), throwsUnsupportedError);
      expect(
        () => result.filtered(folderId: 'a').clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'notices deduplicate per folder identity across pages, not display name',
    () async {
      final a = folder('a')..name = 'Same name';
      final b = folder('b')..name = 'Same name';
      final result = await buildIncrementalUnsyncedOverview(
        folders: [a, b],
        cancellation: OverviewCancellation(),
        inspectPages: (_, consume, _) async {
          await consume({'journal_available': false, 'done': false});
          await consume({'journal_available': false, 'done': true});
        },
      );
      expect(result.notices.length, 2);
      expect(result.total, 0);
      expect(result.complete, isTrue);
      expect(result.truncated, isFalse);
    },
  );

  test(
    'late collision annotations, endpoint errors and current conflicts survive paging',
    () async {
      final f = folder('a')
        ..lastReport = {
          'item_errors': [
            {
              'paths': ['target'],
              'code': 'remote',
            },
            {
              'paths': ['conflict'],
              'code': 'io',
            },
          ],
        };
      final result = await buildIncrementalUnsyncedOverview(
        folders: [f],
        cancellation: OverviewCancellation(),
        inspectPages: (_, consume, _) async {
          await consume({
            'items': [
              {'kind': 'move_remote', 'path': 'source', 'path_to': 'target'},
              {'kind': 'conflict', 'path': 'conflict'},
              {
                'kind': 'move_remote',
                'path': 'blocked',
                'path_to': 'late',
                'case_collision': true,
              },
            ],
            'done': false,
          });
          await consume({
            'case_collisions': [
              ['LATE', 'late'],
            ],
            'done': true,
          });
        },
      );
      expect(
        result.entries.firstWhere((e) => e.path == 'source').status,
        UnsyncedStatus.failed,
      );
      expect(
        result.entries.firstWhere((e) => e.path == 'conflict').status,
        UnsyncedStatus.conflict,
      );
      expect(
        result.entries.firstWhere((e) => e.path == 'blocked').status,
        UnsyncedStatus.blocked,
      );
      expect(result.total, 3);
    },
  );

  test(
    'blocked roots suppress exclusions and failure retains truthful incomplete counts',
    () async {
      final f = folder('a')..excluded = ['excluded'];
      final blocked = await buildIncrementalUnsyncedOverview(
        folders: [f],
        cancellation: OverviewCancellation(),
        inspectPages: (_, consume, _) async {
          await consume({'filesystem_blocked': 'not_found', 'done': true});
        },
      );
      expect(blocked.entries.single.status, UnsyncedStatus.blocked);
      expect(blocked.truncated, isFalse);
      final failed = await buildIncrementalUnsyncedOverview(
        folders: [folder('a')],
        cancellation: OverviewCancellation(),
        inspectPages: (_, consume, _) async {
          await consume({
            'items': [
              {'kind': 'upload', 'path': 'one'},
            ],
            'done': false,
          });
          throw StateError('private diagnostic');
        },
      );
      expect(failed.total, 1);
      expect(failed.truncated, isTrue);
      expect(failed.notices.single.message, contains('could not be compared'));
      expect(failed.notices.single.message, isNot(contains('private')));
    },
  );

  test(
    'active and access-blocked roots bypass native pages and exclusions',
    () async {
      final active = folder('active')
        ..running = true
        ..progress = {
          'path': 'uploading',
          'direction': 'upload',
          'complete': false,
        }
        ..excluded = ['not-a-row'];
      final blocked = folder('blocked')
        ..storageAccessRequired = true
        ..excluded = ['not-a-row'];
      final marker = folder('marker');
      final result = await buildIncrementalUnsyncedOverview(
        folders: [active, blocked, marker],
        cancellation: OverviewCancellation(),
        inspectPages: (f, consume, _) async {
          expect(f.id, 'marker');
          await consume({'sync_running': true});
        },
      );
      expect(result.total, 3);
      expect(result.filtered(status: UnsyncedStatus.skipped), isEmpty);
      expect(result.filtered(folderId: 'active').single.path, 'uploading');
      expect(result.filtered(folderId: 'active').single.retryable, isFalse);
      expect(
        result.filtered(folderId: 'blocked').single.status,
        UnsyncedStatus.blocked,
      );
      expect(
        result.filtered(folderId: 'marker').single.status,
        UnsyncedStatus.pending,
      );
      expect(result.truncated, isFalse);
    },
  );

  test(
    'sync starting during admission preserves exact active evidence and stops paging',
    () async {
      final f = folder('a')..excluded = ['not-a-row'];
      final result = await buildIncrementalUnsyncedOverview(
        folders: [f],
        cancellation: OverviewCancellation(),
        inspectPages: (_, consume, keepGoing) async {
          expect(keepGoing(), isTrue);
          f.running = true;
          f.progress = {
            'path': 'current-transfer',
            'direction': 'download',
            'complete': false,
          };
          await consume({
            'items': [
              for (var i = 0; i < 256; i++)
                {'kind': 'upload', 'path': 'stale-$i'},
            ],
            'done': false,
          });
          expect(
            keepGoing(),
            isFalse,
            reason: 'close redundant cursor after one active observation',
          );
        },
      );
      expect(result.entries.single.path, 'current-transfer');
      expect(result.entries.single.status, UnsyncedStatus.pending);
      expect(result.entries.single.retryable, isFalse);
      expect(result.truncated, isFalse);
      expect(
        result.notices.single.message,
        contains('Active sync evidence only'),
      );
    },
  );

  test(
    'cancellation awaits admitted mapping then rejects publication and later stages',
    () async {
      final token = OverviewCancellation();
      final entered = Completer<void>();
      final release = Completer<void>();
      var ordered = false;
      var published = false;
      token.onPublication = (_) => published = true;
      final work = buildIncrementalUnsyncedOverview(
        folders: [folder('a')],
        cancellation: token,
        inspectPages: (_, consume, _) async {
          await consume({
            'items': [
              {'kind': 'upload', 'path': 'one'},
            ],
            'done': true,
          });
        },
        mapFolder: (f, p, cap, failed) async {
          entered.complete();
          await release.future;
          return mapUnsyncedFolder(f, p, cap, failed);
        },
        orderEntries: (rows) async {
          ordered = true;
          return rows;
        },
      );
      final assertion = expectLater(work, throwsA(isA<OverviewCancelled>()));
      await entered.future;
      token.cancel();
      expect(ordered, isFalse);
      release.complete();
      await assertion;
      expect(published, isFalse);
      expect(ordered, isFalse);
    },
  );

  testWidgets(
    'disposing incremental page cancels admitted producer before mapping',
    (tester) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final finished = Completer<void>();
      late OverviewCancellation token;
      var maps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncOverviewPage(
            onSyncFolder: (_) async {},
            load: (cancellation) async {
              token = cancellation;
              try {
                return await buildIncrementalUnsyncedOverview(
                  folders: [folder('a')],
                  cancellation: token,
                  inspectPages: (_, consume, _) async {
                    entered.complete();
                    await release.future;
                    await consume({
                      'items': [
                        {'kind': 'upload', 'path': 'late'},
                      ],
                      'done': true,
                    });
                  },
                  mapFolder: (f, p, cap, failed) {
                    maps++;
                    return mapUnsyncedFolder(f, p, cap, failed);
                  },
                );
              } finally {
                finished.complete();
              }
            },
          ),
        ),
      );
      for (var i = 0; i < 200 && !entered.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(entered.isCompleted, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      final cancelled = token.isCancelled;
      expect(finished.isCompleted, isFalse);
      release.complete();
      for (var i = 0; i < 200 && !finished.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(finished.isCompleted, isTrue);
      expect(cancelled, isTrue);
      expect(maps, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'page renders first batch and loaded-only counts before terminal completion',
    (tester) async {
      final release = Completer<void>();
      final first = Completer<void>();
      var completed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: SyncOverviewPage(
            onSyncFolder: (_) async {},
            load: (token) =>
                buildIncrementalUnsyncedOverview(
                  folders: [folder('a')],
                  cancellation: token,
                  inspectPages: (_, consume, _) async {
                    await consume({
                      'items': [
                        {'kind': 'upload', 'path': 'first'},
                      ],
                      'done': false,
                    });
                    first.complete();
                    await release.future;
                    for (var start = 1; start < 20017; start += 256) {
                      final end = start + 256 < 20017 ? start + 256 : 20017;
                      await consume({
                        'items': [
                          for (var i = start; i < end; i++)
                            {
                              'kind': i == 20016 ? 'download' : 'upload',
                              'path': i == 20016 ? 'last' : 'file-$i',
                            },
                        ],
                        'done': end == 20017,
                      });
                    }
                  },
                ).then((result) {
                  completed = true;
                  return result;
                }),
          ),
        ),
      );
      for (var i = 0; i < 200 && !first.isCompleted; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(first.isCompleted, isTrue);
      expect(find.text('first'), findsOneWidget);
      expect(find.textContaining('1 items loaded so far'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.text('Everything is in sync.'), findsNothing);
      release.complete();
      for (var i = 0; i < 1000 && !completed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(completed, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('20017 items are not fully in sync.'), findsOneWidget);
      expect(find.text('Cloud only (1)'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.tap(find.text('Cloud only (1)'));
      await tester.pumpAndSettle();
      expect(find.text('last'), findsOneWidget);
      expect(find.text('first'), findsNothing);
    },
  );
}
