import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/sync_controller.dart';
import 'package:nntdrive/sync_overview.dart';

// Reading either keys or an unknown field would copy unused report diagnostics.
class ErrorFieldsOnly extends MapBase<String, dynamic> {
  ErrorFieldsOnly(this.paths, this.code);
  final Object? paths;
  final Object? code;
  final reads = <Object?>[];

  @override
  dynamic operator [](Object? key) {
    reads.add(key);
    if (key == 'paths') return paths;
    if (key == 'code') return code;
    throw StateError('Unused diagnostic read');
  }

  @override
  Iterable<String> get keys => throw StateError('Report enumeration');
  @override
  void operator []=(String key, dynamic value) =>
      throw UnsupportedError('fixed');
  @override
  void clear() => throw UnsupportedError('fixed');
  @override
  dynamic remove(Object? key) => throw UnsupportedError('fixed');
}

class UnusedDiagnostic extends ListBase<Object?> {
  @override
  int get length => throw StateError('Unused diagnostic traversed');
  @override
  set length(int value) => throw UnsupportedError('fixed');
  @override
  Object? operator [](int index) => throw StateError('Unused diagnostic read');
  @override
  void operator []=(int index, Object? value) =>
      throw UnsupportedError('fixed');
}

SyncFolderConfig folder(String id) => SyncFolderConfig(
      id: id,
      name: id,
      localPath: '/unused',
      remoteRootId: id,
    );

void main() {
  test('freezes only structured error paths and code, never diagnostic fields',
      () async {
    final error = ErrorFieldsOnly(['failed'], 'remote');
    final config = folder('f')
      ..lastReport = {
        'item_errors': [error]
      };
    final overview = await buildUnsyncedOverview(
      folders: [config],
      inspect: (_) async => {
        'items': [
          {'kind': 'upload', 'path': 'failed'}
        ],
      },
    );
    expect(error.reads.toSet(), {'paths', 'code'});
    expect(overview.entries.single.status, UnsyncedStatus.failed);
    expect(overview.entries.single.reason, contains('server rejected'));
  });

  test('omits malformed values without traversing their nested diagnostics',
      () async {
    final config = folder('f')
      ..lastReport = {
        'item_errors': [
          null,
          'legacy',
          {'paths': 'not a list', 'code': UnusedDiagnostic()},
          {
            'paths': [null, 7, UnusedDiagnostic(), 'fallback', 'failed'],
            'code': UnusedDiagnostic(),
            'diagnostic': UnusedDiagnostic(),
          },
          {
            'paths': ['failed'],
            'code': 'journal'
          },
        ],
        'errors': UnusedDiagnostic(),
      };
    final overview = await buildUnsyncedOverview(
      folders: [config],
      inspect: (_) async => {
        'items': [
          for (final path in ['fallback', 'failed', 'sibling/failed', 'clean'])
            {'kind': 'upload', 'path': path},
        ],
      },
      mapFolder: (input, plan, budget, failed) async {
        expect(input.lastReport, {
          'item_errors': [
            {
              'paths': ['fallback', 'failed'],
              'code': null
            },
            {
              'paths': ['failed'],
              'code': 'journal'
            },
          ],
        });
        return mapUnsyncedFolder(input, plan, budget, failed);
      },
    );
    final rows = {for (final row in overview.entries) row.path: row};
    expect(rows['fallback']!.reason, contains('last sync attempt failed'));
    expect(rows['failed']!.reason, contains('sync record'));
    expect(rows['sibling/failed']!.status, UnsyncedStatus.localOnly);
    expect(rows['clean']!.status, UnsyncedStatus.localOnly);
    expect(overview.counts, {
      UnsyncedStatus.failed: 2,
      UnsyncedStatus.localOnly: 2,
    });
  });

  test('all folders retain independent path snapshots before inspection awaits',
      () async {
    final paths = <Object?>['before'];
    final error = <String, dynamic>{'paths': paths, 'code': 'remote'};
    final report = <String, dynamic>{
      'item_errors': [error]
    };
    final a = folder('a');
    final b = folder('b')..lastReport = report;
    final overview = await buildUnsyncedOverview(
      folders: [a, b],
      inspect: (config) async {
        if (config.id == 'a') {
          paths[0] = 'after';
          error['code'] = 'journal';
          report.clear();
          return {};
        }
        return {
          'items': [
            {'kind': 'upload', 'path': 'before'},
            {'kind': 'upload', 'path': 'after'},
          ],
        };
      },
    );
    final rows = {for (final row in overview.entries) row.path: row};
    expect(rows['before']!.status, UnsyncedStatus.failed);
    expect(rows['before']!.reason, contains('server rejected'));
    expect(rows['after']!.status, UnsyncedStatus.localOnly);
    expect(overview.folders.map((folder) => folder.total), [0, 2]);
  });
}
