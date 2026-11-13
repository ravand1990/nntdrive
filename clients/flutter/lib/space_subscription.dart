// Subscribing a fixed account space to this device (#95).
//
// A space is an ordinary remote folder node, so subscribing one is an ordinary
// sync entry whose remote root is that node: the local folder is created under
// <documents>/NNTDrive/<space label> and the existing sync engine mirrors the
// space into it. Global is subscribed automatically on every client, because
// the account-wide space is meant to be mirrored everywhere without the user
// adding a folder. Device spaces are an explicit action on the device that wants
// a copy, since mirroring them would download another device's whole tree.
//
// Only the space label is user-visible text. The remote node ID and the sealed
// name stay exactly as the account bootstrap produced them.

import 'package:path/path.dart' as p;

/// Local directory under the user's documents folder that holds the spaces.
const spacesDirectoryName = 'NNTDrive';

/// Reserved device names on Windows: neither the name nor its SUPerscript alias
/// can be used for a directory, even with an extension.
final _reservedStems = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'CONIN\$',
  'CONOUT\$',
  for (final base in ['COM', 'LPT'])
    for (final suffix in [
      '1',
      '2',
      '3',
      '4',
      '5',
      '6',
      '7',
      '8',
      '9',
      '\u00b9',
      '\u00b2',
      '\u00b3'
    ])
      '$base$suffix',
};

/// Longest single path component accepted here. Windows limits a component to
/// 255 units; a short cap keeps room for the " (2)" uniqueness suffix.
const _maxComponentRunes = 96;

/// One safe directory component for a space [label], or null when nothing safe
/// remains. Labels come from device names, so this must never produce a
/// separator, a traversal component, a reserved Windows name or an empty name.
String? safeSpaceFolderName(String label) {
  var name = label
      .replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ')
      .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  // Windows silently drops trailing dots and spaces from a component.
  name = name.replaceAll(RegExp(r'[. ]+$'), '').trim();
  if (name.isEmpty || name == '.' || name == '..') return null;
  final runes = name.runes.toList();
  if (runes.length > _maxComponentRunes) {
    name = String.fromCharCodes(runes.take(_maxComponentRunes)).trim();
  }
  if (name.isEmpty) return null;
  final stem = name.split('.').first.trim().toUpperCase();
  if (_reservedStems.contains(stem)) {
    // Keep the readable label but stop it being a device name.
    name = '$name space';
  }
  return name;
}

/// First free component for [label] inside a spaces directory that already
/// holds [taken]. Comparison is case-insensitive because the common desktop
/// filesystems are; a space never silently reuses another space's folder.
String? uniqueSpaceFolderName(
  String label,
  Iterable<String> taken, {
  int maxAttempts = 50,
}) {
  final base = safeSpaceFolderName(label);
  if (base == null) return null;
  final used = taken.map((name) => name.toLowerCase()).toSet();
  if (!used.contains(base.toLowerCase())) return base;
  for (var attempt = 2; attempt <= maxAttempts; attempt++) {
    final candidate = '$base ($attempt)';
    if (!used.contains(candidate.toLowerCase())) return candidate;
  }
  return null;
}

/// Absolute local directory for a space component, refusing anything that
/// would leave [spacesDirectory].
String spaceDirectoryPath(String spacesDirectory, String folderName) {
  final path = p.join(spacesDirectory, folderName);
  if (!p.isWithin(spacesDirectory, path)) {
    throw ArgumentError.value(
        folderName, 'folderName', 'must stay inside the spaces directory');
  }
  return path;
}
