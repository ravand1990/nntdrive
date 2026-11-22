// Cache limit setting and real device free-space reporting (#199).
//
// The offline cache has always had a fixed 2 GiB ceiling. This file owns the
// small, testable pieces that let the user change it:
//
//   * strict parsing of a typed size ("750 MiB", "1.5 GiB") into bytes, with a
//     floor and ceiling so a typo cannot disable eviction or promise the disk;
//   * per-device persistence in shared preferences (never keyed by account and
//     never naming a file);
//   * one read-only free-space call into the native core, so the cache screen
//     can show what the device actually has left.
//
// Nothing here reads a filename, sends a path, or talks to the backend.

import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'download_cache.dart';
import 'native.dart';

/// Smallest accepted limit. Below this the cache is useless and eviction would
/// run on almost every download.
const int downloadCacheMinLimitBytes = 16 * 1024 * 1024;

/// Largest accepted limit, so a mistyped number cannot promise a terabyte.
const int downloadCacheMaxLimitBytes = 1024 * 1024 * 1024 * 1024;

/// Limits offered as one-tap choices, from smallest to largest.
const List<int> downloadCacheLimitPresets = <int>[
  256 * 1024 * 1024,
  512 * 1024 * 1024,
  1024 * 1024 * 1024,
  downloadCacheDefaultLimitBytes,
  5 * 1024 * 1024 * 1024,
];

/// Device-local preference key. Deliberately not scoped to an account: the
/// cache belongs to the device, not to a login.
const String downloadCacheLimitPrefKey = 'nntdrive.cache.limit_bytes';

const Map<String, int> _unitBytes = <String, int>{
  '': 1,
  'b': 1,
  'k': 1024,
  'kb': 1024,
  'kib': 1024,
  'm': 1024 * 1024,
  'mb': 1024 * 1024,
  'mib': 1024 * 1024,
  'g': 1024 * 1024 * 1024,
  'gb': 1024 * 1024 * 1024,
  'gib': 1024 * 1024 * 1024,
  't': 1024 * 1024 * 1024 * 1024,
  'tb': 1024 * 1024 * 1024 * 1024,
  'tib': 1024 * 1024 * 1024 * 1024,
};

final RegExp _limitPattern = RegExp(r'^([0-9]+(?:[.,][0-9]+)?)\s*([a-z]*)$');

/// Parses a typed cache limit, or returns null when it is not a usable size.
///
/// Accepted: a number with an optional B/KiB/MiB/GiB/TiB suffix, ignoring case
/// and spaces, using a comma or point decimal. Rejected: empty input, negative
/// or zero sizes, unknown units, and anything outside
/// [downloadCacheMinLimitBytes]..[downloadCacheMaxLimitBytes].
int? parseCacheLimitBytes(String input) {
  final text = input.trim().toLowerCase();
  if (text.isEmpty) return null;
  final match = _limitPattern.firstMatch(text);
  if (match == null) return null;
  final number = double.tryParse(match.group(1)!.replaceAll(',', '.'));
  final unit = _unitBytes[match.group(2)!];
  if (number == null || unit == null || !number.isFinite) return null;
  final bytes = (number * unit).round();
  if (bytes < downloadCacheMinLimitBytes) return null;
  if (bytes > downloadCacheMaxLimitBytes) return null;
  return bytes;
}

/// The stored limit, or the built-in default when it is absent or unusable.
Future<int> loadCacheLimitBytes(SharedPreferences prefs) async {
  final stored = prefs.getInt(downloadCacheLimitPrefKey);
  if (stored == null ||
      stored < downloadCacheMinLimitBytes ||
      stored > downloadCacheMaxLimitBytes) {
    return downloadCacheDefaultLimitBytes;
  }
  return stored;
}

/// Persists a limit for this device. Returns true when the value was written.
Future<bool> saveCacheLimitBytes(SharedPreferences prefs, int bytes) async {
  if (bytes < downloadCacheMinLimitBytes ||
      bytes > downloadCacheMaxLimitBytes) {
    throw ArgumentError.value(bytes, 'bytes', 'outside the accepted range');
  }
  return prefs.setInt(downloadCacheLimitPrefKey, bytes);
}

/// Real free bytes for the volume that holds [directory], or null when this
/// build cannot read it. Never throws: a missing reading is reported as such.
Future<int?> deviceFreeSpaceBytes(Directory directory) async {
  try {
    return NativeBridge.instance.freeSpaceBytes(directory.path);
  } catch (_) {
    return null;
  }
}

/// Byte counts in the units a person compares, matching the rest of the client.
String formatCacheBytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final text = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}
