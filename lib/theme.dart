/// The app's two themes, and the handful of sizes the inbox's rules fix.
///
/// A file of its own rather than two `ThemeData` literals in `main.dart`,
/// because INB-23's 48dp floor is a rule and not a taste: it applies to the
/// row, every chip, Delete, INB-13's control and each switch, and a number
/// repeated at six call sites is a number that drifts at one of them. The
/// initials circle is not in that list — it is decoration (INB-23) — and it is
/// sized here for a different reason, which [Metrics.avatar] states.
library;

import 'package:flutter/material.dart';

/// Sizes INB-23 fixes, in logical pixels.
abstract final class Metrics {
  /// The smallest side any control this area draws may have (INB-23).
  static const double minTarget = 48;

  /// The leading circle (INB-1). Exactly [minTarget] — but not because it is a
  /// control: INB-23's correction of 22 September 2026 says the circle and its
  /// app badge are decoration inside the row, carrying no semantic label and no
  /// tap target of their own, because what they stand for is already in the
  /// row's own label. The row is the control.
  ///
  /// The size is fixed here anyway, and for its own reason: at the 1.3x text
  /// scale INB-23 renders at, a circle sized to its contents grows with the
  /// initials inside it, and the 40dp one a `ListTile` gives by default does
  /// not — so the initials spill out of it. 48dp is the number that holds two
  /// initials at that scale without the row reflowing around them.
  static const double avatar = minTarget;

  /// The source-app badge on the corner of that circle (INB-1).
  static const double appBadge = 18;

  /// The width INB-6's swipe reveals. Wider than [minTarget] so the label fits
  /// beside the icon at the 1.3x text scale INB-23 renders at.
  static const double deleteExtent = 96;

  /// The gutter INB-13 names for the thread's bottom bar, used here for the
  /// list's own horizontal padding so a row's text starts where the thread's
  /// does.
  static const double gutter = 16;
}

/// The seed the whole palette comes from. One colour, both brightnesses.
const Color _seed = Colors.indigo;

ThemeData replyboxTheme({Brightness brightness = Brightness.light}) {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: _seed,
    brightness: brightness,
  );
  return ThemeData(
    colorScheme: scheme,
    // INB-23: the floor applies to everything Material lays out for us too —
    // an `IconButton` or a `Chip` that shrinks to its content is exactly how a
    // 48dp rule gets lost.
    materialTapTargetSize: MaterialTapTargetSize.padded,
    visualDensity: VisualDensity.standard,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 3,
    ),
    chipTheme: ChipThemeData(
      showCheckmark: false,
      side: BorderSide(color: scheme.outlineVariant),
      labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      secondaryLabelStyle: TextStyle(color: scheme.onSecondaryContainer),
    ),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}
