import 'dart:async';

import 'package:flutter/material.dart';

import 'account_search.dart';

/// Search state lives only in this unlocked session, never restoration/prefs.
class AccountSearchPage extends StatefulWidget {
  const AccountSearchPage({super.key, required this.index});
  final AccountSearch index;
  @override
  State<AccountSearchPage> createState() => _AccountSearchPageState();
}

class _AccountSearchPageState extends State<AccountSearchPage> {
  final _text = TextEditingController();
  final _extension = TextEditingController();
  final _min = TextEditingController();
  final _max = TextEditingController();
  final _after = TextEditingController();
  final _before = TextEditingController();
  SearchKind _kind = SearchKind.any;
  bool _favorites = false;
  List<SearchEntry> _results = [];
  String? _error;
  Timer? _debounce;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    widget.index.addListener(_indexChanged);
    if (widget.index.ready) {
      unawaited(_run());
    } else {
      unawaited(_rebuild());
    }
  }

  void _indexChanged() {
    if (!mounted) return;
    setState(() {
      // A rebuild may replace ancestry while an older query is returning.
      // Drop view-owned results on every snapshot/history/lifecycle notification;
      // the admitted query repopulates them after validating its generation.
      _results = [];
      if (widget.index.closed) {
        _generation++;
        _debounce?.cancel();
        for (final c in [_text, _extension, _min, _max, _after, _before]) {
          c.clear();
        }
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.index.removeListener(_indexChanged);
    for (final c in [_text, _extension, _min, _max, _after, _before]) {
      c.dispose();
    }
    super.dispose();
  }

  SearchFilter _filter() {
    int? size(String value) {
      if (value.isEmpty) return null;
      final n = int.tryParse(value);
      if (n == null || n < 0) throw const FormatException();
      return n;
    }

    DateTime? date(String value) {
      if (value.isEmpty) return null;
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
        throw const FormatException();
      }
      final parsed = DateTime.tryParse('${value}T00:00:00Z');
      if (parsed == null ||
          parsed.toIso8601String().substring(0, 10) != value) {
        throw const FormatException();
      }
      return parsed;
    }

    final min = size(_min.text.trim());
    final max = size(_max.text.trim());
    final after = date(_after.text.trim());
    final before = date(_before.text.trim());
    if ((min != null && max != null && min > max) ||
        (after != null && before != null && !after.isBefore(before))) {
      throw const FormatException();
    }
    return SearchFilter(
      text: _text.text,
      kind: _kind,
      extension: _extension.text,
      minSize: min,
      maxSize: max,
      modifiedAfter: after,
      modifiedBefore: before,
      favoritesOnly: _favorites,
    );
  }

  void _changed([String? _]) {
    _generation++;
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_run()),
    );
  }

  Future<void> _run({bool remember = false, bool save = false}) async {
    final generation = ++_generation;
    try {
      final filter = _filter();
      final results = await widget.index.search(filter);
      if (!mounted || generation != _generation) return;
      if (remember || save) widget.index.remember(filter, save: save);
      setState(() {
        _results = results;
        _error = null;
      });
    } on FormatException catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _results = [];
          _error =
              'Use nonnegative byte sizes and valid YYYY-MM-DD date ranges.';
        });
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _results = [];
          _error = 'Search unavailable. Unlock or rebuild the index.';
        });
      }
    }
  }

  Future<void> _rebuild() async {
    try {
      await widget.index.rebuild();
      if (mounted) await _run();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Rebuild failed. Existing indexed results remain available offline; they may be stale.',
        );
      }
    }
  }

  void _restore(SearchFilter filter) {
    _text.text = filter.text;
    _extension.text = filter.extension;
    _min.text = filter.minSize?.toString() ?? '';
    _max.text = filter.maxSize?.toString() ?? '';
    _after.text =
        filter.modifiedAfter?.toIso8601String().substring(0, 10) ?? '';
    _before.text =
        filter.modifiedBefore?.toIso8601String().substring(0, 10) ?? '';
    setState(() {
      _kind = filter.kind;
      _favorites = filter.favoritesOnly;
    });
    _changed();
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    double width = 145,
  }) =>
      SizedBox(
        width: width,
        child: TextField(
          controller: controller,
          onChanged: _changed,
          decoration: InputDecoration(labelText: label),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final index = widget.index;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Search all files'),
        actions: [
          IconButton(
            onPressed: index.building ? null : _rebuild,
            icon: const Icon(Icons.refresh),
            tooltip: 'Rebuild account index',
          ),
        ],
      ),
      body: Column(
        children: [
          Flexible(
              child: SingleChildScrollView(
                  child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                TextField(
                  controller: _text,
                  autofocus: true,
                  onChanged: _changed,
                  onSubmitted: (_) => _run(remember: true),
                  decoration: const InputDecoration(
                    labelText: 'Search decrypted names',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<SearchKind>(
                      value: _kind,
                      items: SearchKind.values
                          .map(
                            (k) => DropdownMenuItem(
                              value: k,
                              child: Text(
                                k == SearchKind.any ? 'All types' : k.name,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (k) {
                        setState(() => _kind = k!);
                        _changed();
                      },
                    ),
                    _field(_extension, 'Extension', width: 95),
                    _field(_min, 'Min bytes', width: 100),
                    _field(_max, 'Max bytes', width: 100),
                    _field(_after, 'Modified since (UTC)'),
                    _field(_before, 'Modified before (UTC)'),
                    FilterChip(
                      label: const Text('Favorites'),
                      selected: _favorites,
                      onSelected: (v) {
                        setState(() => _favorites = v);
                        _changed();
                      },
                    ),
                    TextButton(
                      onPressed: () => _run(remember: true),
                      child: const Text('Search'),
                    ),
                    TextButton(
                      onPressed: () => _run(save: true),
                      child: const Text('Save filter'),
                    ),
                    TextButton(
                      onPressed: () => _restore(const SearchFilter()),
                      child: const Text('Clear filters'),
                    ),
                  ],
                ),
                if (index.recent.isNotEmpty || index.saved.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final f in index.saved)
                        ActionChip(
                          label: Text(
                            'Saved: ${f.text.isEmpty ? 'Filter' : f.text}',
                          ),
                          onPressed: () => _restore(f),
                        ),
                      for (final f in index.recent)
                        ActionChip(
                          label: Text(
                            'Recent: ${f.text.isEmpty ? 'Filter' : f.text}',
                          ),
                          onPressed: () => _restore(f),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                Text(
                  '${index.count} indexed · top 200 ranked results · session memory only. '
                  'Rebuild to refresh; indexed names work offline until sign-out. '
                  'Dates are server metadata. Sync status is not inspected here; open the folder to check.',
                ),
                if (_error != null)
                  Text(_error!, key: const Key('search-error')),
              ],
            ),
          ))),
          if (index.building) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty
                ? const Center(child: Text('No indexed results'))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final entry = _results[i];
                      return ListTile(
                        title: Text(entry.name),
                        leading: Icon(
                          entry.file.isDir
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                        ),
                        subtitle: Text(
                          '${index.folderPath(entry)} · ${entry.file.isDir ? 'Folder' : '${entry.file.size} bytes'} · Sync status unknown',
                        ),
                        trailing:
                            entry.file.favorite ? const Icon(Icons.star) : null,
                        onTap: () {
                          try {
                            index.remember(_filter());
                          } on FormatException catch (_) {
                            return;
                          }
                          Navigator.pop(context, entry);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
