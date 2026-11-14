import 'package:flutter/material.dart';

/// One item action offered by the browser's item menu.
///
/// The kinds are shared by files and folders so the page has exactly one menu
/// and one place that decides when an action is unavailable and why.
enum ItemActionKind {
  open,
  download,
  versions,
  uploadVersion,
  favorite,
  rename,
  move,
  copy,
  delete,
}

/// A single menu row: label, icon, and whether it can run right now.
///
/// [disabledReason] is shown in place of the subtitle whenever the action is
/// unavailable, so a greyed-out entry always explains itself instead of being a
/// silently dead control.
class ItemActionSpec {
  const ItemActionSpec({
    required this.kind,
    required this.label,
    required this.icon,
    this.subtitle,
    this.enabled = true,
    this.disabledReason,
    this.destructive = false,
  });

  final ItemActionKind kind;
  final String label;
  final IconData icon;
  final String? subtitle;
  final bool enabled;
  final String? disabledReason;
  final bool destructive;
}

/// Folder deletion is not implemented: it would strand the folder's children
/// because the client has no Trash or recursive delete yet.
const String folderDeleteUnavailable =
    'Folder deletion waits for Trash and restore (#81). Empty a folder first to remove it safely.';

/// Why a mutating action cannot start while another operation is running.
const String busyActionUnavailable = 'Finish the operation that is already running.';

/// Every action the browser offers for one file or folder, in a fixed order.
///
/// Files lead with their content actions; folders lead with opening them. The
/// row itself only shows a single overflow control, so this list is the single
/// source of truth for what exists and what is disabled.
List<ItemActionSpec> itemActionSpecs({
  required bool isDir,
  required bool favorite,
  required bool busy,
}) {
  final mutating = <ItemActionSpec>[
    ItemActionSpec(
      kind: ItemActionKind.rename,
      label: isDir ? 'Rename folder' : 'Rename file',
      icon: Icons.edit_outlined,
      enabled: !busy,
      disabledReason: busy ? busyActionUnavailable : null,
    ),
    ItemActionSpec(
      kind: ItemActionKind.move,
      label: isDir ? 'Move folder' : 'Move file',
      icon: Icons.drive_file_move_outlined,
      enabled: !busy,
      disabledReason: busy ? busyActionUnavailable : null,
    ),
    ItemActionSpec(
      kind: ItemActionKind.copy,
      label: isDir ? 'Copy folder' : 'Copy file',
      icon: Icons.copy_outlined,
      enabled: !busy,
      disabledReason: busy ? busyActionUnavailable : null,
    ),
  ];

  if (isDir) {
    return <ItemActionSpec>[
      const ItemActionSpec(
        kind: ItemActionKind.open,
        label: 'Open folder',
        icon: Icons.folder_open_outlined,
      ),
      ...mutating,
      const ItemActionSpec(
        kind: ItemActionKind.delete,
        label: 'Delete folder',
        icon: Icons.delete_outline,
        destructive: true,
        enabled: false,
        disabledReason: folderDeleteUnavailable,
      ),
    ];
  }

  return <ItemActionSpec>[
    const ItemActionSpec(
      kind: ItemActionKind.download,
      label: 'Download and verify',
      icon: Icons.download,
    ),
    const ItemActionSpec(
      kind: ItemActionKind.versions,
      label: 'Version history',
      icon: Icons.history,
    ),
    ItemActionSpec(
      kind: ItemActionKind.uploadVersion,
      label: 'Upload new version',
      icon: Icons.upgrade,
      subtitle: 'Keeps the previous revision recoverable',
      enabled: !busy,
      disabledReason: busy ? busyActionUnavailable : null,
    ),
    ItemActionSpec(
      kind: ItemActionKind.favorite,
      label: favorite ? 'Remove favorite' : 'Add favorite',
      icon: favorite ? Icons.star : Icons.star_border,
      enabled: !busy,
      disabledReason: busy ? busyActionUnavailable : null,
    ),
    ...mutating,
    ItemActionSpec(
      kind: ItemActionKind.delete,
      label: 'Delete file',
      icon: Icons.delete_outline,
      subtitle: 'Posted Usenet articles cannot be physically deleted',
      destructive: true,
      enabled: !busy,
      disabledReason: busy ? busyActionUnavailable : null,
    ),
  ];
}

/// The shared bottom sheet for one item's actions.
///
/// Uses full-height [ListTile] rows, so every action stays a visible, 48dp-plus
/// target with a text label; nothing depends on a gesture or an icon alone.
class ItemActionsSheet extends StatelessWidget {
  const ItemActionsSheet({
    super.key,
    required this.title,
    required this.details,
    required this.specs,
    required this.onSelected,
  });

  final String title;
  final String details;
  final List<ItemActionSpec> specs;
  final ValueChanged<ItemActionKind> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                title: Text(title, style: theme.textTheme.titleMedium),
                subtitle: Text(details),
              ),
              const Divider(height: 1),
              for (final spec in specs)
                ListTile(
                  enabled: spec.enabled,
                  leading: Icon(
                    spec.icon,
                    color: spec.enabled && spec.destructive
                        ? theme.colorScheme.error
                        : null,
                  ),
                  title: Text(spec.label),
                  subtitle: spec.enabled
                      ? (spec.subtitle == null ? null : Text(spec.subtitle!))
                      : Text(spec.disabledReason ?? 'Not available right now'),
                  onTap: spec.enabled ? () => onSelected(spec.kind) : null,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
