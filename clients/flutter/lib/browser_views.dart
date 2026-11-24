import 'package:flutter/material.dart';

import 'api.dart';
import 'local_availability.dart';
import 'local_availability_widgets.dart';

enum BrowserSort { name, size, modified }

enum BrowserView { list, grid }

/// One already-decrypted listing, owned by the browser view. No IO/crypto.
/// Ordering is cached independently of filtering and unrelated rebuilds.
class BrowserListing {
  BrowserListing(List<RemoteFile> files, String Function(RemoteFile) nameFor)
    : _entries = [for (final file in files) (file: file, name: nameFor(file))];

  final List<({RemoteFile file, String name})> _entries;
  BrowserSort? _sort;
  bool? _descending;
  String? _query;
  List<RemoteFile> _ordered = const [];
  List<RemoteFile> _visible = const [];

  List<RemoteFile> visible(BrowserSort sort, bool descending, String query) {
    final folded = query.toLowerCase();
    if (_sort != sort || _descending != descending) {
      final entries = List.of(_entries);
      entries.sort((a, b) {
        int primary;
        switch (sort) {
          case BrowserSort.name:
            primary = a.name.toLowerCase().compareTo(b.name.toLowerCase());
          case BrowserSort.size:
            // Directory metadata sizes are not content sizes.
            primary = (a.file.isDir ? 0 : a.file.size).compareTo(
              b.file.isDir ? 0 : b.file.size,
            );
          case BrowserSort.modified:
            final at = a.file.updatedAt;
            final bt = b.file.updatedAt;
            // Unknown times stay last in either direction.
            if (at == null && bt != null) return 1;
            if (at != null && bt == null) return -1;
            primary = at == null ? 0 : at.compareTo(bt!);
        }
        if (primary != 0) return descending ? -primary : primary;
        final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        if (name != 0) return name;
        final exact = a.name.compareTo(b.name);
        return exact != 0 ? exact : a.file.id.compareTo(b.file.id);
      });
      _ordered = List.unmodifiable(entries.map((e) => e.file));
      _sort = sort;
      _descending = descending;
      _query = null;
    }
    if (_query != folded) {
      final matches = {
        for (final entry in _entries)
          if (entry.name.toLowerCase().contains(folded)) entry.file.id,
      };
      _visible = folded.isEmpty
          ? _ordered
          : List.unmodifiable(
              _ordered.where((file) => matches.contains(file.id)),
            );
      _query = folded;
    }
    return _visible;
  }
}

class BrowserViewControls extends StatelessWidget {
  const BrowserViewControls({
    super.key,
    required this.view,
    required this.sort,
    required this.descending,
    required this.onView,
    required this.onSort,
    required this.onDirection,
  });
  final BrowserView view;
  final BrowserSort sort;
  final bool descending;
  final ValueChanged<BrowserView> onView;
  final ValueChanged<BrowserSort> onSort;
  final VoidCallback onDirection;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final mode in BrowserView.values)
          TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => onView(mode),
            icon: Icon(
              mode == BrowserView.list ? Icons.view_list : Icons.grid_view,
            ),
            label: Text(
              '${mode == BrowserView.list ? 'List' : 'Grid'}${view == mode ? ' ✓' : ''}',
            ),
          ),
        PopupMenuButton<BrowserSort>(
          tooltip: 'Sort files',
          onSelected: onSort,
          itemBuilder: (_) => [
            for (final value in BrowserSort.values)
              PopupMenuItem(
                value: value,
                height: 48,
                child: Text(_sortLabel(value)),
              ),
          ],
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort),
                  const SizedBox(width: 8),
                  Flexible(child: Text('Sort: ${_sortLabel(sort)}')),
                ],
              ),
            ),
          ),
        ),
        TextButton.icon(
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onDirection,
          icon: Icon(descending ? Icons.arrow_downward : Icons.arrow_upward),
          label: Text(descending ? 'Descending' : 'Ascending'),
        ),
      ],
    ),
  );
}

String _sortLabel(BrowserSort sort) => switch (sort) {
  BrowserSort.name => 'Name',
  BrowserSort.size => 'Size',
  BrowserSort.modified => 'Modified',
};

/// Both surfaces use the same opaque-ID callback adapters and status widgets.
class BrowserFilesView extends StatelessWidget {
  const BrowserFilesView({
    super.key,
    required this.files,
    required this.view,
    required this.nameFor,
    required this.availabilityFor,
    required this.pinned,
    required this.onOpen,
    required this.onActions,
    required this.onReveal,
    required this.onDetails,
  });
  final List<RemoteFile> files;
  final BrowserView view;
  final String Function(RemoteFile) nameFor;
  final LocalAvailability Function(RemoteFile) availabilityFor;
  final bool Function(RemoteFile) pinned;
  final ValueChanged<RemoteFile> onOpen;
  final ValueChanged<RemoteFile> onActions;
  final ValueChanged<RemoteFile> onReveal;
  final ValueChanged<RemoteFile> onDetails;

  @override
  Widget build(BuildContext context) {
    Widget item(BuildContext context, int index) {
      final file = files[index];
      return BrowserFileTile(
        key: ValueKey(file.id),
        file: file,
        name: nameFor(file),
        local: availabilityFor(file),
        pinned: pinned(file),
        grid: view == BrowserView.grid,
        onOpen: () => onOpen(file),
        onActions: () => onActions(file),
        onReveal: () => onReveal(file),
        onDetails: () => onDetails(file),
      );
    }

    if (view == BrowserView.list) {
      return ListView.separated(
        itemCount: files.length,
        itemBuilder: item,
        padding: const EdgeInsets.only(bottom: 88),
        physics: const AlwaysScrollableScrollPhysics(),
        separatorBuilder: (_, _) => const Divider(height: 1),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = (constraints.maxWidth / (280 * scale)).floor().clamp(
          1,
          8,
        );
        return GridView.builder(
          itemCount: files.length,
          itemBuilder: item,
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            mainAxisExtent: 180 * scale + 64,
          ),
        );
      },
    );
  }
}

class BrowserFileTile extends StatelessWidget {
  const BrowserFileTile({
    super.key,
    required this.file,
    required this.name,
    required this.local,
    required this.pinned,
    required this.grid,
    required this.onOpen,
    required this.onActions,
    required this.onReveal,
    required this.onDetails,
  });
  final RemoteFile file;
  final String name;
  final LocalAvailability local;
  final bool pinned;
  final bool grid;
  final VoidCallback onOpen, onActions, onReveal, onDetails;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final icon = Icon(
      file.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
      semanticLabel: file.isDir ? 'Folder' : 'File',
    );
    final status = LocalAvailabilityLabel(
      state: local,
      details: file.isDir ? 'Folder' : _bytes(file.size),
    );
    final actions = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (file.favorite)
          const Icon(Icons.star, size: 18, semanticLabel: 'Favourite'),
        if (pinned && !file.isDir)
          const Icon(
            Icons.offline_pin,
            size: 18,
            semanticLabel: 'Kept offline',
          ),
        LocalRevealButton(state: local, onReveal: onReveal),
        IconButton(
          tooltip: 'Details for $name',
          icon: const Icon(Icons.info_outline),
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: onDetails,
        ),
        IconButton(
          tooltip: 'More actions for $name',
          icon: const Icon(Icons.more_vert),
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
          ),
          onPressed: onActions,
        ),
      ],
    );
    final title = Tooltip(
      message: name,
      child: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!grid && constraints.maxWidth >= 520 && scale <= 1.3) {
          return ListTile(
            leading: icon,
            title: title,
            subtitle: status,
            trailing: actions,
            onTap: onOpen,
          );
        }
        return Card(
          margin: grid ? EdgeInsets.zero : const EdgeInsets.all(4),
          child: InkWell(
            onTap: onOpen,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      icon,
                      const SizedBox(width: 8),
                      Expanded(child: title),
                    ],
                  ),
                  const SizedBox(height: 8),
                  status,
                  if (grid) const Spacer(),
                  Align(alignment: Alignment.centerRight, child: actions),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

String _bytes(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
