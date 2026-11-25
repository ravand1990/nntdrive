import 'package:flutter/material.dart';

/// Browser entry points only. Child pages retain their existing routes/owners.
enum SessionDestination {
  global('Global', Icons.public),
  devices('Devices', Icons.folder_copy_outlined),
  sync('Sync', Icons.sync),
  activity('Activity', Icons.notifications_none),
  search('Search', Icons.travel_explore),
  trash('Trash', Icons.delete_outline),
  settings('Settings', Icons.settings_outlined),
  manageDevices('Manage devices', Icons.devices_outlined);

  const SessionDestination(this.label, this.icon);
  final String label;
  final IconData icon;

  String get description => switch (this) {
    devices => 'Account root listing, including Global and device spaces',
    manageDevices => 'Device sessions and revocation',
    settings => 'Account and settings',
    _ => label,
  };
}

/// Adaptive chrome; never creates or owns a session/controller or navigator.
/// The child always occupies the same element slot, including at breakpoints.
class SessionNavigation extends StatefulWidget {
  const SessionNavigation({
    super.key,
    required this.child,
    required this.onSelected,
    this.selected,
  });

  final Widget child;
  final ValueChanged<SessionDestination> onSelected;
  final SessionDestination? selected;

  @override
  State<SessionNavigation> createState() => _SessionNavigationState();
}

class _SessionNavigationState extends State<SessionNavigation> {
  bool _collapsed = false;
  final _compactScroll = ScrollController();

  @override
  void dispose() {
    _compactScroll.dispose();
    super.dispose();
  }

  Future<void> _menu({
    List<SessionDestination> destinations = SessionDestination.values,
  }) async {
    final destination = await showModalBottomSheet<SessionDestination>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          children: [
            for (final destination in destinations)
              Tooltip(
                message: destination.description,
                child: ListTile(
                  key: ValueKey('menu-${destination.name}'),
                  minTileHeight: 48,
                  minVerticalPadding: 12,
                  leading: Icon(destination.icon),
                  title: Text(destination.label),
                  // Keep enlarged labels reachable above a short open keyboard;
                  // the full description remains discoverable via the tooltip.
                  subtitle:
                      destination.description == destination.label ||
                          MediaQuery.textScalerOf(context).scale(14) / 14 > 1.3
                      ? null
                      : Text(destination.description),
                  selected: widget.selected == destination,
                  onTap: () => Navigator.pop(context, destination),
                ),
              ),
          ],
        ),
      ),
    );
    if (mounted && destination != null) widget.onSelected(destination);
  }

  static const _files = [SessionDestination.global, SessionDestination.devices];
  static const _more = [
    SessionDestination.trash,
    SessionDestination.settings,
    SessionDestination.manageDevices,
  ];

  Widget _compactNavigation(double width) {
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // Keep full labels and 48dp targets even on very narrow/enlarged layouts.
    // Horizontal scrolling avoids stealing multiple rows from the browser.
    final itemWidth = (width / 5).clamp(72.0 * scale, double.infinity);
    final colors = Theme.of(context).colorScheme;
    Widget item(
      String name,
      String label,
      IconData icon,
      bool selected,
      VoidCallback onPressed,
    ) => SizedBox(
      width: itemWidth,
      child: Semantics(
        key: ValueKey('navigation-$name'),
        selected: selected,
        child: Tooltip(
          message: label,
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              backgroundColor: selected ? colors.secondaryContainer : null,
              foregroundColor: selected
                  ? colors.onSecondaryContainer
                  : colors.onSurface,
            ),
            onPressed: onPressed,
            child: scale > 1.3
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon),
                      const SizedBox(width: 4),
                      Flexible(child: Text(label, textAlign: TextAlign.center)),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon),
                      Text(label, textAlign: TextAlign.center),
                    ],
                  ),
          ),
        ),
      ),
    );
    return Scrollbar(
      key: const ValueKey('navigation-compact'),
      controller: _compactScroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _compactScroll,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            item(
              'files',
              'Files',
              Icons.folder_outlined,
              _files.contains(widget.selected),
              () => _menu(destinations: _files),
            ),
            for (final destination in [
              SessionDestination.search,
              SessionDestination.sync,
              SessionDestination.activity,
            ])
              item(
                destination.name,
                destination.label,
                destination.icon,
                widget.selected == destination,
                () => widget.onSelected(destination),
              ),
            item(
              'more',
              'More',
              Icons.more_horiz,
              _more.contains(widget.selected),
              () => _menu(destinations: _more),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final enlarged = MediaQuery.textScalerOf(context).scale(14) / 14 > 1.3;
      // A tablet rail must leave at least 528dp for the existing browser.
      final compact = enlarged || constraints.maxWidth < 600;
      final labelled = !compact && constraints.maxWidth >= 1200 && !_collapsed;
      final width = compact
          ? 0.0
          : labelled
          ? 240.0
          : 72.0;
      return Material(
        color: Theme.of(context).colorScheme.surface,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: compact ? MediaQuery.viewInsetsOf(context).bottom : 0,
          ),
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: compact,
            child: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: width,
                          child: compact
                              ? null
                              : ListView(
                                  key: ValueKey(
                                    labelled
                                        ? 'navigation-sidebar'
                                        : 'navigation-rail',
                                  ),
                                  children: [
                                    if (constraints.maxWidth >= 1200)
                                      IconButton(
                                        tooltip: labelled
                                            ? 'Collapse navigation'
                                            : 'Expand navigation',
                                        constraints: const BoxConstraints(
                                          minHeight: 48,
                                          minWidth: 48,
                                        ),
                                        onPressed: () => setState(
                                          () => _collapsed = !_collapsed,
                                        ),
                                        icon: Icon(
                                          labelled
                                              ? Icons.chevron_left
                                              : Icons.chevron_right,
                                        ),
                                      )
                                    else
                                      IconButton(
                                        tooltip: 'Navigation destinations',
                                        constraints: const BoxConstraints(
                                          minHeight: 48,
                                          minWidth: 48,
                                        ),
                                        onPressed: _menu,
                                        icon: const Icon(Icons.menu),
                                      ),
                                    for (final destination
                                        in SessionDestination.values)
                                      if (labelled)
                                        ListTile(
                                          key: ValueKey(
                                            'navigation-${destination.name}',
                                          ),
                                          minTileHeight: 48,
                                          leading: Icon(destination.icon),
                                          title: Text(destination.label),
                                          subtitle:
                                              destination ==
                                                  SessionDestination.devices
                                              ? const Text(
                                                  'Account root listing',
                                                )
                                              : null,
                                          selected:
                                              widget.selected == destination,
                                          onTap: () =>
                                              widget.onSelected(destination),
                                        )
                                      else
                                        IconButton(
                                          key: ValueKey(
                                            'navigation-${destination.name}',
                                          ),
                                          tooltip:
                                              '${destination.label}: ${destination.description}',
                                          isSelected:
                                              widget.selected == destination,
                                          constraints: const BoxConstraints(
                                            minHeight: 48,
                                            minWidth: 48,
                                          ),
                                          icon: Icon(destination.icon),
                                          onPressed: () =>
                                              widget.onSelected(destination),
                                        ),
                                  ],
                                ),
                        ),
                        Expanded(child: widget.child),
                      ],
                    ),
                  ),
                  if (compact) _compactNavigation(constraints.maxWidth),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
