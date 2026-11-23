import 'account_search.dart';
import 'api.dart';

/// Fresh opaque-ID traversal for both search results and dashboard folder links.
/// Display paths are never parsed or used as filesystem/HTTP paths.
Future<List<SearchEntry>> resolveSearchLocation({
  required AccountSearch index,
  required SearchEntry entry,
  required bool containingOnly,
  required Future<List<RemoteFile>> Function(String? parent) list,
  required Future<Map<String, String>> Function(List<RemoteFile>) decrypt,
}) => index.readSnapshot((snapshot) async {
  if (!identical(snapshot[entry.file.id], entry)) {
    throw const SearchUnavailable();
  }
  final trail = [...index.ancestors(entry), entry];
  final parents = <SearchEntry>[];
  String? parent;
  for (var i = 0; i < trail.length; i++) {
    final files = await list(parent);
    // Never decrypt a late response after close. readSnapshot owns drain and
    // rejects a replacement snapshot before returning the resolved location.
    if (index.closed) throw const SearchUnavailable();
    final matches = files.where((file) => file.id == trail[i].file.id).toList();
    if (matches.length != 1) throw const SearchUnavailable();
    final current = matches.single;
    if (current.parentId != parent || current.isDir != trail[i].file.isDir) {
      throw const SearchUnavailable();
    }
    final names = await decrypt([current]);
    if (index.closed) throw const SearchUnavailable();
    final name = names[current.id];
    if (name == null) throw const SearchUnavailable();
    if (i < trail.length - 1 || (current.isDir && !containingOnly)) {
      if (!current.isDir) throw const SearchUnavailable();
      parents.add(SearchEntry(current, name));
    }
    parent = current.id;
  }
  return parents;
});
