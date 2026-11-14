import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Window width from which the app treats the surface as a tablet or a
/// landscape phone instead of a portrait phone column.
const double appWideBreakpoint = 900;

/// Widest readable column for browser lists and long-form content.
const double appMaxContentWidth = 840;

/// Widest a dialog may become, so landscape and tablet dialogs stay readable
/// instead of stretching edge to edge.
const double appDialogMaxWidth = 600;

/// System bar style matching the active brightness.
///
/// Bars stay transparent so content draws behind them; only the icons switch
/// between dark and light.
SystemUiOverlayStyle appSystemUiOverlayStyle(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark;
  return base.copyWith(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    // iOS reads the inverse of the Android icon brightness.
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness:
        dark ? Brightness.light : Brightness.dark,
    systemNavigationBarContrastEnforced: false,
    systemStatusBarContrastEnforced: false,
  );
}

/// Lets Android draw the app behind the system bars.
///
/// Desktop windows keep their native frame, so this is a no-op there.
Future<void> applyEdgeToEdgeSystemUi() async {
  if (!Platform.isAndroid) return;
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

/// Applies [appSystemUiOverlayStyle] for the active theme brightness to
/// everything below it, so rotating or switching theme restyles the bars.
class SystemUiStyleScope extends StatelessWidget {
  const SystemUiStyleScope({super.key, required this.child, this.brightness});

  final Widget child;

  /// Overrides the theme brightness, for entry points without a theme.
  final Brightness? brightness;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: appSystemUiOverlayStyle(
        brightness ?? Theme.of(context).brightness,
      ),
      child: child,
    );
  }
}

/// Centres [child] in a readable column on wide windows and leaves it full
/// width on phones.
class AppContentFrame extends StatelessWidget {
  const AppContentFrame({
    super.key,
    required this.child,
    this.maxWidth = appMaxContentWidth,
  });

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// Bottom padding for content anchored to the screen edge: the larger of the
/// system bar inset and the open keyboard, so nothing hides behind either.
EdgeInsets appBottomBarPadding(BuildContext context, {double extra = 0}) {
  final media = MediaQuery.of(context);
  final bottom = math.max(media.padding.bottom, media.viewInsets.bottom);
  return EdgeInsets.only(bottom: bottom + extra);
}
