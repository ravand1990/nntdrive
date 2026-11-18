import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/conflict_paths.dart';
import 'package:nntdrive/local_availability.dart';
import 'package:nntdrive/search_status.dart';
import 'package:nntdrive/search_status_conflicts.dart';
import 'package:nntdrive/sync_controller.dart';

void main() {
  test(
    'production conflict indexes preserve root isolation and status precedence',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'conflict-roots-',
      );
      final root = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      await File(
        '${root.path}/report (conflict dev T).txt',
      ).writeAsString('preserved');
      final first = SyncFolderConfig(
        id: 'a',
        name: 'A',
        localPath: root.path,
        remoteRootId: 'a',
      )..conflictFiles = ['report (conflict dev T).txt'];
      final second = SyncFolderConfig(
        id: 'b',
        name: 'B',
        localPath: root.path,
        remoteRootId: 'b',
      );
      for (final folder in [first, second]) {
        folder.lastReport = {
          'item_errors': [
            {
              'operation': 'download',
              'code': 'io',
              'paths': ['report.txt'],
            },
          ],
        };
        folder.progress = {'path': 'report.txt', 'complete': false};
      }
      final snapshot = <String, SearchEntry>{
        for (final id in ['a', 'b']) ...{
          id: SearchEntry(RemoteFile(id, null, id, true, 0, true, 1, null), id),
          '$id-file': SearchEntry(
            RemoteFile('$id-file', id, 'sealed', false, 0, true, 1, null),
            'report.txt',
          ),
        },
      };
      for (final running in [false, true]) {
        first.running = second.running = running;
        final result = await inspectSearchStatuses(
          snapshot: snapshot,
          folders: [first, second],
          cancelled: () => false,
        );
        expect(result['a-file'], SearchStatus.conflict);
        expect(
          result['b-file'],
          running ? SearchStatus.syncing : SearchStatus.error,
        );
      }
    },
  );

  test(
    'candidate inference preserves exact spelling, roots and immutable dedupe',
    () async {
      const copy = 'dir/report (conflict dev T).txt';
      final result = await indexSearchStatusConflicts(
        3,
        Stream.fromIterable([
          [
            (root: 0, path: copy),
            (root: 0, path: '../bad (conflict dev T).txt'),
            (root: 0, path: '/bad (conflict dev T).txt'),
            (root: 0, path: 'dir/name (conflict unclosed.txt'),
          ],
          [
            (root: 0, path: copy),
            (root: 1, path: copy),
            (root: 0, path: 'dir (conflict dev T)/report.txt'),
            (root: 0, path: 'dir/.hidden (conflict dev T)'),
            (root: 0, path: 'dir/name (conflict old T) (conflict new T).txt'),
          ],
        ]),
      );
      expect(result[0].candidatesByOriginal, {
        'dir/report.txt': [copy],
        'dir/.hidden': ['dir/.hidden (conflict dev T)'],
        'dir/name (conflict old T).txt': [
          'dir/name (conflict old T) (conflict new T).txt',
        ],
      });
      expect(result[1].candidatesByOriginal, {
        'dir/report.txt': [copy],
      });
      expect(result[2].exact, isEmpty);
      expect(result[2].candidatesByOriginal, isEmpty);
      expect(result[0].exact, contains('../bad (conflict dev T).txt'));
      expect(result[0].candidatesByOriginal['report.txt'], isNull);
      expect(result[0].candidatesByOriginal['dir/Report.txt'], isNull);
      expect(
        () => result[0].candidatesByOriginal.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => result[0].candidatesByOriginal['dir/report.txt']!.clear(),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'prepared hints revalidate live candidates, missing ancestors and links',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'prepared-conflicts-',
      );
      final root = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      final folder = SyncFolderConfig(
        id: 'r',
        name: 'Root',
        localPath: root.path,
        remoteRootId: 'r',
      );
      const first = 'dir/report (conflict dev T).txt';
      const second = 'dir/report (conflict other T).txt';
      folder.conflictFiles = [first, second, 'exact.txt'];
      final prepared = (await indexSearchStatusConflicts(
        1,
        Stream.value([
          for (final path in folder.conflictFiles) (root: 0, path: path),
        ]),
      )).single;
      final empty = (await indexSearchStatusConflicts(
        1,
        const Stream.empty(),
      )).single;
      Future<LocalAvailability> inspect(
        String relative, {
        PreparedConflictPaths? evidence,
        bool dir = false,
      }) => inspectLocalAvailability(
        ancestry: [
          (id: 'r', name: 'Root'),
          for (final part in relative.split('/')) (id: part, name: part),
        ],
        folders: [folder],
        isDir: dir,
        conflictPathsByFolder: evidence == null ? null : {folder: evidence},
      );
      await Directory('${root.path}/dir').create();
      final candidate = File('${root.path}/$second');
      await candidate.writeAsString('preserved');
      var state = await inspect('dir/report.txt', evidence: prepared);
      expect(
        state.displayLabel,
        'Conflict',
      ); // First candidate missing; second exists.
      expect(state.path, isNull); // Missing originals remain non-revealable.
      expect(
        (await inspect('dir/report.txt', evidence: empty)).displayLabel,
        'Cloud only',
      );
      expect(
        (await inspect('dir/report.txt')).displayLabel,
        'Conflict',
      ); // Browser fallback.
      await File('${root.path}/dir/report.txt').writeAsString('local');
      expect(
        (await inspect('dir/report.txt', evidence: prepared)).displayLabel,
        'Conflict',
      );
      await candidate.delete();
      expect(
        (await inspect('dir/report.txt', evidence: prepared)).displayLabel,
        'Local',
      );
      await Directory(candidate.path).create();
      expect(
        (await inspect('dir/report.txt', evidence: prepared)).displayLabel,
        'Local',
      );
      await Directory(candidate.path).delete();
      // Windows link creation can require privileges absent on CI runners.
      if (!Platform.isWindows) {
        await Link(candidate.path).create('${root.path}/dir/report.txt');
        expect(
          (await inspect('dir/report.txt', evidence: prepared)).displayLabel,
          'Local',
        );
        await Link(candidate.path).delete();
      }
      await candidate.writeAsString('preserved');
      expect(
        (await inspect('dir/notreport.txt', evidence: prepared)).displayLabel,
        'Cloud only',
      );
      expect(
        (await inspect(
          'dir/report.txt',
          evidence: prepared,
          dir: true,
        )).displayLabel,
        'Error',
      );
      await Directory('${root.path}/dir').rename('${root.path}/elsewhere');
      expect(
        (await inspect('dir/report.txt', evidence: prepared)).displayLabel,
        'Cloud only',
      );
      if (!Platform.isWindows) {
        await Link('${root.path}/dir').create('${root.path}/elsewhere');
        expect(
          (await inspect('dir/report.txt', evidence: prepared)).displayLabel,
          'Error',
        );
        await Link('${root.path}/dir').delete();
      }
      await File('${root.path}/exact.txt').writeAsString('local');
      expect(
        (await inspect('exact.txt', evidence: empty)).displayLabel,
        'Local',
      );
      expect((await inspect('exact.txt')).displayLabel, 'Conflict');
      expect(
        (await inspect('exact.txt', evidence: prepared)).displayLabel,
        'Conflict',
      );
      await File('${root.path}/exact.txt').delete();
      expect(
        (await inspect('exact.txt', evidence: prepared)).displayLabel,
        'Cloud only',
      );
    },
  );
}
