import 'dart:collection';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/search_status_conflicts.dart';
import 'package:nntdrive/sync_controller.dart';

class CountedConflicts extends ListBase<String> {
  CountedConflicts(this.values);
  final List<String> values;
  int reads = 0;
  @override
  int get length => values.length;
  @override
  set length(int value) => throw UnsupportedError('resize');
  @override
  String operator [](int index) {
    reads++;
    return values[index];
  }

  @override
  void operator []=(int index, String value) => throw UnsupportedError('write');
}

void main() {
  test('prepared conflict evidence avoids repeated full-list reads', () async {
    final root = await Directory.systemTemp.createTemp('conflict-scans-');
    addTearDown(() => root.delete(recursive: true));
    final conflicts = CountedConflicts([
      for (var i = 0; i < 40; i++) 'other-$i (conflict dev T).txt',
    ]);
    final folder = SyncFolderConfig(
      id: 'r',
      name: 'Root',
      localPath: await root.resolveSymbolicLinks(),
      remoteRootId: 'r',
    )..conflictFiles = conflicts;
    final prepared = (await indexSearchStatusConflicts(
      1,
      Stream.value([for (final path in conflicts) (root: 0, path: path)]),
    )).single;
    for (var i = 0; i < 5; i++) {
      await File('${root.path}/file-$i.txt').writeAsString('local');
      final result = await inspectLocalAvailability(
        ancestry: [(id: 'r', name: 'Root'), (id: 'f$i', name: 'file-$i.txt')],
        folders: [folder],
        isDir: false,
        conflictPathsByFolder: {folder: prepared},
      );
      expect(result.displayLabel, 'Local');
    }
    expect(
      conflicts.reads,
      lessThanOrEqualTo(40),
      reason: 'conflict paths must be indexed once, not scanned per item',
    );
  });
}
