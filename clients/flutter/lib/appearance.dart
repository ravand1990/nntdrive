import 'package:flutter/material.dart';

/// Install-local, nonsecret browser spacing. Never changes hit-target density.
enum BrowserDensity {
  comfortable,
  compact;

  static BrowserDensity fromPreference(String? value) =>
      value == 'compact' ? compact : comfortable;
}

class AppearanceDialog extends StatefulWidget {
  const AppearanceDialog({
    super.key,
    required this.themeMode,
    required this.density,
    required this.onTheme,
    required this.onDensity,
  });

  final ThemeMode themeMode;
  final BrowserDensity density;
  final ValueChanged<ThemeMode> onTheme;
  final ValueChanged<BrowserDensity> onDensity;

  @override
  State<AppearanceDialog> createState() => _AppearanceDialogState();
}

class _AppearanceDialogState extends State<AppearanceDialog> {
  late ThemeMode _theme = widget.themeMode;
  late BrowserDensity _density = widget.density;

  Widget choice(String label, bool selected, VoidCallback select) => Semantics(
    checked: selected,
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
      child: ListTile(
        minVerticalPadding: 12,
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_off,
        ),
        title: Text(label),
        onTap: select,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Appearance'),
    scrollable: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
    content: SizedBox(
      width: 400,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Theme'),
          for (final mode in ThemeMode.values)
            choice(
              switch (mode) {
                ThemeMode.system => 'System',
                ThemeMode.light => 'Light',
                ThemeMode.dark => 'Dark',
              },
              _theme == mode,
              () {
                setState(() => _theme = mode);
                widget.onTheme(mode);
              },
            ),
          const SizedBox(height: 16),
          const Text('Browser density'),
          const Text(
            'Saved on this installation. Buttons keep their full size.',
          ),
          for (final density in BrowserDensity.values)
            choice(
              density == BrowserDensity.compact ? 'Compact' : 'Comfortable',
              _density == density,
              () {
                setState(() => _density = density);
                widget.onDensity(density);
              },
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
    ],
  );
}
