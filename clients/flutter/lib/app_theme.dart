import 'package:flutter/material.dart';

import 'app_layout.dart';

/// The single brand seed. Every colour role in the app derives from it; no
/// widget picks its own one-off colour.
const Color nntDriveSeedColor = Color(0xFF0B6BCB);

/// Opacity of the overlay shown while active operations finish.
const double nntDriveBusyOverlayOpacity = 0.87;

/// Material 3 theme for both brightnesses.
///
/// Colour roles, typography and component defaults all come from
/// [ColorScheme.fromSeed], so dark mode and contrast come from one seed rather
/// than per-widget overrides.
ThemeData buildNntDriveTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: nntDriveSeedColor,
    brightness: brightness,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: scheme.surfaceTint,
      scrolledUnderElevation: 3,
    ),
    dialogTheme: const DialogThemeData(
      constraints: BoxConstraints(maxWidth: appDialogMaxWidth),
      insetPadding: EdgeInsets.symmetric(horizontal: 24, vertical: 24),
    ),
  );
}

/// Colour roles the app uses that Material 3 does not name directly.
extension NntDriveThemeColors on ThemeData {
  /// Full-screen overlay while operations finish; follows the active
  /// brightness instead of assuming a light surface.
  Color get busyOverlayColor =>
      colorScheme.surface.withValues(alpha: nntDriveBusyOverlayOpacity);

  /// Confirmed/healthy state. Always paired with an icon or label so status is
  /// never conveyed by colour alone.
  Color get connectedIndicatorColor => colorScheme.primary;
}
