import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/account_search.dart';
import 'package:nntdrive/api.dart';
import 'package:nntdrive/storage_usage.dart';

const threshold = 10 * 1024 * 1024;

SearchEntry dated(String id, int size, String? date, {bool dir = false}) =>
    SearchEntry(
      RemoteFile.fromJson({
        'id': id,
        'size': size,
        'is_dir': dir,
        'updated_at': date,
      }),
      '$id.bin',
    );

void main() {
  test(
    'oldest large uses UTC instants, size then ID ties and inclusive limit',
    () async {
      final usage = await runStorageUsage({
        'z': dated('z', threshold, '2020-01-01T01:00:00+02:00'),
        'b': dated('b', threshold, '2020-01-01T00:00:00Z'),
        'a': dated('a', threshold, '2019-12-31T19:00:00-05:00'),
        'c': dated('c', threshold + 1, '2020-01-01T00:00:00Z'),
        'small': dated('small', threshold - 1, '1990-01-01T00:00:00Z'),
        'missing': dated('missing', threshold, null),
        'bad': dated('bad', threshold, 'not a timestamp'),
        'smallMissing': dated('smallMissing', 1, null),
        'dir': dated('dir', threshold, '1980-01-01T00:00:00Z', dir: true),
        'dirMissing': dated('dirMissing', threshold, null, dir: true),
      });
      // Dynamic access also makes the pre-feature run an executable regression.
      final dynamic result = usage;
      final List<dynamic> oldest = result.oldestLarge;
      expect(oldest.map((dynamic f) => f.path), [
        'z.bin',
        'c.bin',
        'a.bin',
        'b.bin',
      ]);
      expect(oldest.first.updatedAt, DateTime.utc(2019, 12, 31, 23));
      expect(oldest.every((dynamic f) => f.updatedAt.isUtc == true), isTrue);
      expect(result.unknownLargeDates, 2);
      expect(() => oldest.clear(), throwsUnsupportedError);
      expect(usage.files, 8);
      expect(usage.largest.first.path, 'c.bin');
    },
  );

  test('100k eligible files retain only deterministic oldest 20', () async {
    final dynamic result = await runStorageUsage({
      for (var i = 99999; i >= 0; i--)
        '$i': dated('$i', threshold + i, '2020-01-01T00:00:00Z'),
    });
    final List<dynamic> oldest = result.oldestLarge;
    expect(oldest.length, 20);
    expect(oldest.first.path, '99999.bin');
    expect(oldest.last.path, '99980.bin');
    expect(result.files, 100000);
    expect(result.bytes, 100000 * threshold + 4999950000);
    expect(result.unknownLargeDates, 0);
  });

  test('empty and all unknown dates have no invented oldest row', () async {
    final dynamic empty = await runStorageUsage({});
    expect(empty.oldestLarge, isEmpty);
    expect(empty.unknownLargeDates, 0);
    final dynamic unknown = await runStorageUsage({
      'bad': dated('bad', threshold, 'broken'),
    });
    expect(unknown.oldestLarge, isEmpty);
    expect(unknown.unknownLargeDates, 1);
    expect(unknown.bytes, threshold);
  });
}
