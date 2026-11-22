import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nntdrive/cache_settings.dart';
import 'package:nntdrive/download_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('parseCacheLimitBytes', () {
    test('accepts the offered presets exactly', () {
      for (final preset in downloadCacheLimitPresets) {
        expect(
          parseCacheLimitBytes(formatCacheBytes(preset)),
          preset,
          reason: 'a preset must round-trip through its own label',
        );
      }
    });

    test('accepts typed sizes with and without spaces', () {
      expect(parseCacheLimitBytes('750 MiB'), 750 * 1024 * 1024);
      expect(parseCacheLimitBytes('750mib'), 750 * 1024 * 1024);
      expect(parseCacheLimitBytes(' 2048 MB '), 2048 * 1024 * 1024);
      expect(parseCacheLimitBytes('1.5 GiB'), 1536 * 1024 * 1024);
      expect(parseCacheLimitBytes('1,5 GiB'), 1536 * 1024 * 1024);
      expect(parseCacheLimitBytes('2G'), 2 * 1024 * 1024 * 1024);
      expect(parseCacheLimitBytes('512000000 B'), 512000000);
    });

    test('accepts the exact range ends', () {
      expect(parseCacheLimitBytes('16 MiB'), downloadCacheMinLimitBytes);
      expect(parseCacheLimitBytes('1 TiB'), downloadCacheMaxLimitBytes);
    });

    test('rejects sizes that cannot be applied', () {
      for (final input in <String>[
        '',
        '   ',
        'abc',
        '0',
        '0 MiB',
        '-1 GiB',
        '8 MiB',
        '2 TiB',
        '1 PiB',
        '512 MiB extra',
        'MiB',
        '1.2.3 GiB',
      ]) {
        expect(
          parseCacheLimitBytes(input),
          isNull,
          reason: '"$input" must not be accepted',
        );
      }
    });
  });

  test('formatCacheBytes keeps the existing client wording', () {
    expect(formatCacheBytes(0), '0 B');
    expect(formatCacheBytes(512), '512 B');
    expect(formatCacheBytes(1536), '1.5 KiB');
    expect(formatCacheBytes(2 * 1024 * 1024 * 1024), '2.0 GiB');
  });

  group('stored limit', () {
    test('an absent value falls back to the default', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      expect(await loadCacheLimitBytes(prefs), downloadCacheDefaultLimitBytes);
    });

    test('an out-of-range stored value falls back to the default', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        downloadCacheLimitPrefKey: 1,
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await loadCacheLimitBytes(prefs), downloadCacheDefaultLimitBytes);

      SharedPreferences.setMockInitialValues(<String, Object>{
        downloadCacheLimitPrefKey: downloadCacheMaxLimitBytes * 2,
      });
      final again = await SharedPreferences.getInstance();
      expect(await loadCacheLimitBytes(again), downloadCacheDefaultLimitBytes);
    });

    test('a saved limit is read back after a restart', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      const chosen = 512 * 1024 * 1024;
      expect(await saveCacheLimitBytes(prefs, chosen), isTrue);

      // A fresh handle sees the stored value, which is what a restart does.
      final reopened = await SharedPreferences.getInstance();
      expect(await loadCacheLimitBytes(reopened), chosen);
    });

    test('saving an out-of-range limit is refused', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final prefs = await SharedPreferences.getInstance();
      expect(() => saveCacheLimitBytes(prefs, 1), throwsArgumentError);
      expect(await loadCacheLimitBytes(prefs), downloadCacheDefaultLimitBytes);
    });

    test('the applies-at-once limit is what the cache reports', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'nntdrive-limit-cache',
      );
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });
      final cache = DownloadCache(
        root: Directory('${sandbox.path}/cache'),
        limitBytes: 1024 * 1024,
      );
      await cache.open();
      await cache.setLimit(512 * 1024 * 1024);
      expect(cache.limitBytes, 512 * 1024 * 1024);
      expect(cache.usage.limitBytes, 512 * 1024 * 1024);
    });
  });

  test(
    'the native core reports real free space for an existing directory',
    () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'nntdrive-free-space',
      );
      addTearDown(() async {
        if (await sandbox.exists()) await sandbox.delete(recursive: true);
      });
      final free = await deviceFreeSpaceBytes(sandbox);
      expect(free, isNotNull, reason: 'a real statfs reading is expected');
      expect(free!, greaterThan(0));
    },
    skip: Platform.environment['NNTDRIVE_FFI_PATH'] == null
        ? 'The native core is not configured in this environment.'
        : false,
  );
}
