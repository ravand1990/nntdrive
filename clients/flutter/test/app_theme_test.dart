import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nntdrive/app_layout.dart';
import 'package:nntdrive/app_theme.dart';

void main() {
  test('both brightnesses use Material 3 roles from one seed', () {
    final light = buildNntDriveTheme(Brightness.light);
    final dark = buildNntDriveTheme(Brightness.dark);
    expect(light.useMaterial3, isTrue);
    expect(dark.useMaterial3, isTrue);
    expect(light.colorScheme.brightness, Brightness.light);
    expect(dark.colorScheme.brightness, Brightness.dark);
    expect(light.scaffoldBackgroundColor, light.colorScheme.surface);
    expect(dark.scaffoldBackgroundColor, dark.colorScheme.surface);
    expect(light.dialogTheme.constraints?.maxWidth, appDialogMaxWidth);
  });

  test('busy overlay follows the active brightness instead of fixed white', () {
    final light = buildNntDriveTheme(Brightness.light);
    final dark = buildNntDriveTheme(Brightness.dark);
    expect(light.busyOverlayColor, isNot(dark.busyOverlayColor));
    expect(light.busyOverlayColor.a, closeTo(nntDriveBusyOverlayOpacity, 0.01));
    expect(dark.busyOverlayColor.a, closeTo(nntDriveBusyOverlayOpacity, 0.01));
    expect(
        light.busyOverlayColor.r, closeTo(light.colorScheme.surface.r, 0.001));
    expect(dark.busyOverlayColor.r, closeTo(dark.colorScheme.surface.r, 0.001));
  });

  test('confirmed status uses a scheme role rather than a raw green', () {
    for (final brightness in Brightness.values) {
      final theme = buildNntDriveTheme(brightness);
      expect(theme.connectedIndicatorColor, theme.colorScheme.primary);
    }
  });

  test('text keeps WCAG AA contrast on the surfaces the app uses', () {
    // WCAG 2.1 AA needs 4.5:1 for normal-size text. The app renders body text,
    // secondary text, filled buttons and error cards from these roles, so a
    // seed change must not quietly make any of them unreadable.
    double ratio(Color foreground, Color background) {
      final a = foreground.computeLuminance();
      final b = background.computeLuminance();
      return (a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05));
    }

    for (final brightness in Brightness.values) {
      final theme = buildNntDriveTheme(brightness);
      final s = theme.colorScheme;
      final pairs = {
        'body text on the page': (s.onSurface, s.surface),
        'secondary text on the page': (s.onSurfaceVariant, s.surface),
        'row text on a card': (s.onSurface, s.surfaceContainerHighest),
        'secondary text on a card': (s.onSurfaceVariant, s.surfaceContainerHighest),
        'filled button label': (s.onPrimary, s.primary),
        'error text on the page': (s.error, s.surface),
        'conflict card text': (s.onErrorContainer, s.errorContainer),
        // The app overrides these two itself, so they can drift from the
        // generated pairs that Material guarantees.
        'app bar title': (
          theme.appBarTheme.foregroundColor!,
          theme.appBarTheme.backgroundColor!
        ),
        'page background': (s.onSurface, theme.scaffoldBackgroundColor),
      };
      for (final entry in pairs.entries) {
        expect(ratio(entry.value.$1, entry.value.$2), greaterThanOrEqualTo(4.5),
            reason: '${entry.key} must stay readable in $brightness');
      }
    }
  });

  test('system bars stay transparent and only the icons follow brightness', () {
    final light = appSystemUiOverlayStyle(Brightness.light);
    expect(light.statusBarColor, Colors.transparent);
    expect(light.systemNavigationBarColor, Colors.transparent);
    expect(light.statusBarIconBrightness, Brightness.dark);
    expect(light.systemNavigationBarIconBrightness, Brightness.dark);
    expect(light.systemNavigationBarContrastEnforced, isFalse);

    final dark = appSystemUiOverlayStyle(Brightness.dark);
    expect(dark.statusBarColor, Colors.transparent);
    expect(dark.statusBarIconBrightness, Brightness.light);
    expect(dark.systemNavigationBarIconBrightness, Brightness.light);
  });

  testWidgets('system bar scope follows the active theme brightness',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildNntDriveTheme(Brightness.dark),
      home: const SystemUiStyleScope(child: Scaffold(body: SizedBox())),
    ));
    final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>).first);
    expect(region.value.statusBarIconBrightness, Brightness.light);
  });
}
