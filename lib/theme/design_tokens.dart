// Shared design values. Edit here, not in the widgets: both the app and the
// design gallery (tool/design_gallery/) read these, so a change shows up in
// the app and in the gallery's cards at once.
//
// A value earns a token when more than one widget needs it, or when the number
// is a design decision rather than an implementation detail. One-off geometry
// that only makes sense inside a single widget stays where it is.
//
// Colours that follow the user's accent live in accent_theme.dart; the ones
// here are the fixed chrome that does not.

import 'package:flutter/material.dart';

/// Corner radii, smallest to largest. A neutral scale rather than semantic
/// names: the existing 22 call sites do not agree on what each step means, so
/// naming them by role would be inventing intent.
abstract final class Radii {
  static const double xs = 2;
  static const double sm = 4;
  static const double md = 6;
  static const double lg = 8;
  static const double xl = 12;

  /// Every radius the app uses, for the gallery's scale card.
  static const List<double> scale = [xs, sm, md, lg, xl];
}

abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
}

/// Fixed chrome around web content: not accent-derived, so these stay put when
/// the user picks a different accent colour.
abstract final class Chrome {
  static const Color barLight = Color(0xFFF5F5F5);
  static const Color barDark = Color(0xFF1E1E1E);
  static const Color hairlineLight = Color(0xFFE0E0E0);
  static const Color hairlineDark = Color(0xFF3E3E3E);
  static const double hairlineWidth = 0.5;

  static Color bar({required bool isDark}) => isDark ? barDark : barLight;
  static Color hairline({required bool isDark}) =>
      isDark ? hairlineDark : hairlineLight;
}

/// The padlock in the URL bar. Green only for https; anything else reads as
/// not-secure rather than as an error.
///
/// Shade 700/600 rather than the plain Material colours: the same padlock is
/// drawn on both chrome bars, and `Colors.green`/`Colors.grey` sit at 2.55:1
/// and 2.46:1 on the light one, under the 3:1 that a meaningful non-text
/// indicator needs. These clear it on both.
abstract final class SecurityIndicator {
  static const Color secure = Color(0xFF388E3C);
  static const Color insecure = Color(0xFF757575);
}

abstract final class IconSizes {
  /// Inline with body text (the URL bar padlock).
  static const double inline = 16;

  /// Tappable icon in a row or app bar.
  static const double action = 20;

  /// Icon inside a floating circular button.
  static const double floating = 22;
}

abstract final class TapTargets {
  /// Floor for a compact icon button that still has to be hittable.
  static const double compact = 32;
}

abstract final class Motion {
  /// Press / release feedback. Short enough to feel attached to the finger.
  static const Duration press = Duration(milliseconds: 100);

  /// One step of a list scrolling itself while something is dragged at its
  /// edge.
  static const Duration autoScrollTick = Duration(milliseconds: 16);

  /// A released control gliding to where it rests.
  static const Duration settle = Duration(milliseconds: 250);
}

abstract final class Elevations {
  static const double floating = 3;
  static const double floatingActive = 8;
}

/// The tab-strip button floats over site content, so it is translucent enough
/// to show what it covers and grows while dragged.
abstract final class FloatingButton {
  static const double surfaceOpacity = 0.85;
  static const double padding = 10;
  static const double dragScale = 1.2;
}

/// Rows of the tab list (TAB-011).
abstract final class TabRows {
  /// A tab that holds no webview is drawn at this strength, as a browser
  /// fades an unloaded tab.
  static const double unloadedOpacity = 0.5;

  /// The row being dragged, left in place (TAB-015).
  static const double draggingOpacity = 0.3;

  /// The line that shows where a dragged tab will land.
  static const double dropLineWidth = 2;

  /// How close to the list's top or bottom a drag starts scrolling it, and
  /// how far one step scrolls.
  static const double autoScrollEdge = 48;
  static const double autoScrollStep = 8;
}

/// One colour per container (TAB-018): a tab row is marked with the colour of
/// the container it runs in, so which container a tab uses is never a guess.
/// Two sets, the same hues in order, each holding 3:1 against the surfaces of
/// its brightness so the mark reads as a graphic.
abstract final class ContainerColors {
  /// Blue, turquoise, green, yellow, orange, red, pink, purple.
  static const List<Color> light = [
    Color(0xFF1565C0),
    Color(0xFF00838F),
    Color(0xFF2E7D32),
    Color(0xFF8D6E00),
    Color(0xFFE65100),
    Color(0xFFC62828),
    Color(0xFFAD1457),
    Color(0xFF6A1B9A),
  ];

  static const List<Color> dark = [
    Color(0xFF64B5F6),
    Color(0xFF4DD0E1),
    Color(0xFF81C784),
    Color(0xFFFFD54F),
    Color(0xFFFFB74D),
    Color(0xFFE57373),
    Color(0xFFF06292),
    Color(0xFFBA68C8),
  ];

  /// The bar at the start of a tab row.
  static const double markWidth = 3;

  static Color of(int index, {required Brightness brightness}) {
    final set = brightness == Brightness.dark ? dark : light;
    return set[index % set.length];
  }
}

abstract final class TextSizes {
  /// The URL bar's editable text.
  static const double url = 14;
}
