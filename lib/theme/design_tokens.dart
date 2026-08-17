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

  static Color bar(bool isDark) => isDark ? barDark : barLight;
  static Color hairline(bool isDark) => isDark ? hairlineDark : hairlineLight;
}

/// The padlock in the URL bar. Green only for https; anything else reads as
/// not-secure rather than as an error.
abstract final class SecurityIndicator {
  static const Color secure = Colors.green;
  static const Color insecure = Colors.grey;
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

abstract final class TextSizes {
  /// The URL bar's editable text.
  static const double url = 14;
}
