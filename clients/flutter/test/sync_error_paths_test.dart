import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/sync_controller.dart';

class CountedErrors extends IterableBase<dynamic> {
  CountedErrors(this.values);
  final List<dynamic> values;
  int visits = 0;
  @override
  Iterator<dynamic> get iterator => values.map((value) {
        visits++;
        return value;
      }).iterator;
}

void main() {
  test('error path index reads each report once and keeps exact valid paths',
      () async {
    final errors = CountedErrors([
      {
        'operation': 'move',
        'code': 'io',
        'paths': ['a/file', 'b/file']
      },
      {
        'operation': 'download',
        'code': 'io',
        'paths': ['a/file', 42]
      },
      {
        'operation': 'download',
        'paths': ['missing-code']
      },
      {
        'operation': 1,
        'code': 'io',
        'paths': ['bad-operation']
      },
      {'operation': 'download', 'code': 'io', 'paths': 'not-a-list'},
      null,
    ]);
    final paths = await indexSyncErrorPaths(errors, cancelled: () => false);
    expect(paths, {'a/file', 'b/file'});
    expect(errors.visits, errors.values.length);
    expect(paths.contains('file'), isFalse);
    expect(paths.contains('A/file'), isFalse);
    expect(() => paths.add('later'), throwsUnsupportedError);
  });

  test('indexed status avoids per-entry report scans and preserves precedence',
      () async {
    final report = CountedErrors(List.generate(
        500,
        (i) => {
              'operation': 'download',
              'code': 'io',
              'paths': ['file-$i']
            }));
    final paths = await indexSyncErrorPaths(report, cancelled: () => false);
    final folder = SyncFolderConfig(
        id: 's',
        name: 's',
        localPath: '/unused',
        remoteRootId: 'r',
        lastReport: {'item_errors': report.values});
    // Any fallback to the report is observable, without elapsed-time assertions.
    final counted = ReadCountList(report.values);
    folder.lastReport = {'item_errors': counted};
    for (var i = 0; i < 500; i++) {
      final state = LocalAvailability('Local', 'presence only',
          folder: folder, relativePath: 'file-$i', failedPaths: paths);
      expect(state.displayLabel, 'Error');
      expect(state.displayExplanation, contains('last completed sync attempt'));
    }
    expect(counted.reads, 0);
    final state = LocalAvailability('Local', 'presence only',
        folder: folder, relativePath: 'file-1', failedPaths: paths);
    folder.running = true;
    expect(state.displayLabel, 'Local');
    folder.progress = {'path': 'file-1', 'complete': false};
    expect(state.displayLabel, 'Syncing');
    folder.running = false;
    expect(
        LocalAvailability('Conflict', 'conflict',
                folder: folder, relativePath: 'file-1', failedPaths: paths)
            .displayLabel,
        'Conflict');
    expect(
        LocalAvailability('Cloud only', 'absent',
                folder: folder,
                relativePath: 'nested/file-1',
                failedPaths: paths)
            .displayLabel,
        'Cloud only');
    expect(
        LocalAvailability('Local', 'presence',
            folder: folder,
            relativePath: 'file-1',
            failedPaths: const {}).displayLabel,
        'Local');
    // Unindexed browser consumers retain their existing dynamic report behavior.
    expect(
        LocalAvailability('Local', 'presence',
                folder: folder, relativePath: 'file-1')
            .displayLabel,
        'Error');
    expect(counted.reads, greaterThan(0));
  });

  test('index yields within a large report and observes cancellation',
      () async {
    var cancelled = false;
    final errors = CountedErrors(List.generate(
        1000,
        (i) => {
              'operation': 'download',
              'code': 'io',
              'paths': ['file-$i']
            }));
    final future = indexSyncErrorPaths(errors, cancelled: () => cancelled);
    Future<void>.delayed(Duration.zero, () => cancelled = true);
    await expectLater(future, throwsStateError);
    expect(errors.visits, lessThan(errors.values.length));
    cancelled = false;
    final manyPaths = ReadCountList(List.generate(1000, (i) => 'file-$i'));
    final singleError = indexSyncErrorPaths([
      {'operation': 'move', 'code': 'io', 'paths': manyPaths}
    ], cancelled: () => cancelled);
    Future<void>.delayed(Duration.zero, () => cancelled = true);
    await expectLater(singleError, throwsStateError);
    expect(manyPaths.reads, lessThan(manyPaths.length));
    await expectLater(
        indexSyncErrorPaths([], cancelled: () => true), throwsStateError);
  });
}

class ReadCountList extends ListBase<dynamic> {
  ReadCountList(this.values);
  final List<dynamic> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('fixture');
  @override
  dynamic operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, dynamic value) =>
      throw UnsupportedError('fixture');
}
