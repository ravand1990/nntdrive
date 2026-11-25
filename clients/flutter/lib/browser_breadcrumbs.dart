import 'package:flutter/material.dart';

/// Display-only ancestry; callbacks carry an ancestor count, never a name path.
class BrowserBreadcrumbs extends StatelessWidget {
  const BrowserBreadcrumbs({
    super.key,
    required this.names,
    required this.onVisit,
  });

  final List<String> names;
  final ValueChanged<int>? onVisit;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      final compact =
          bounds.maxWidth < 700 ||
          MediaQuery.textScalerOf(context).scale(1) > 1.3 ||
          names.length > 4;
      Widget crumb(int count, String name) => Flexible(
        child: Tooltip(
          message: name,
          child: TextButton(
            key: ValueKey('breadcrumb-$count'),
            onPressed: onVisit == null || count == names.length
                ? null
                : () => onVisit!(count),
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
      return Row(
        children: [
          crumb(0, 'Browser root'),
          if (compact && names.length > 1)
            PopupMenuButton<int>(
              tooltip: 'Ancestor folders',
              enabled: onVisit != null,
              itemBuilder: (_) => [
                for (var i = 0; i < names.length - 1; i++)
                  PopupMenuItem(
                    value: i + 1,
                    onTap: onVisit == null ? null : () => onVisit!(i + 1),
                    child: Text(names[i]),
                  ),
              ],
              icon: const Icon(Icons.more_horiz),
            ),
          for (var i = compact ? names.length - 1 : 0; i < names.length; i++)
            if (i >= 0) ...[
              const Icon(Icons.chevron_right, size: 18),
              crumb(i + 1, names[i]),
            ],
        ],
      );
    },
  );
}
