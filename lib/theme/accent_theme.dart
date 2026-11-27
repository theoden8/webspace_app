import 'dart:math' as math;

import 'package:flutter/material.dart';

const Color accentBlue = Color(0xFF6B8DD6);
const Color accentGreen = Color(0xFF7be592);
const Color accentPurple = Color(0xFF9B7BD6);
const Color accentOrange = Color(0xFFE59B5B);
const Color accentRed = Color(0xFFD66B6B);
const Color accentPink = Color(0xFFD66BA8);
const Color accentTeal = Color(0xFF5BC4C4);
const Color accentYellow = Color(0xFFD6C86B);

/// Black or white, whichever contrasts more with [background].
///
/// The accents span a wide luminance range (green 0xFF7be592 against white is
/// 1.56:1), so tying this to the theme's brightness instead of the colour
/// itself makes label text on light accents unreadable.
Color _onAccent(Color background) {
  final l = background.computeLuminance();
  return (l + 0.05) / 0.05 >= 1.05 / (l + 0.05) ? Colors.black : Colors.white;
}

/// Whether a theme is the one the OS asks for with Increase Contrast or High
/// Contrast (`MediaQuery.highContrast`, A11Y-010).
enum ThemeContrast {
  standard(0.0),
  high(1.0);

  const ThemeContrast(this.seedContrastLevel);

  /// What `ColorScheme.fromSeed` takes for the neutral roles.
  final double seedContrastLevel;
}

/// Build a ColorScheme that preserves the full saturation of [accent].
/// Uses fromSeed only for neutral surface/background colors, then overrides
/// all accent-derived roles so nothing gets desaturated by Material 3's HCT.
ColorScheme buildAccentColorScheme(Color accent,
    {required Brightness brightness,
    ThemeContrast contrast = ThemeContrast.standard}) {
  final bool isLight = brightness == Brightness.light;
  final hsl = HSLColor.fromColor(accent);

  // Container: a tinted but lighter/darker version of the accent
  final primaryContainer = isLight
      ? hsl.withLightness((hsl.lightness * 0.3 + 0.7).clamp(0.80, 0.92)).withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0)).toColor()
      : hsl.withLightness((hsl.lightness * 0.35).clamp(0.12, 0.25)).withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0)).toColor();

  final onPrimaryContainer = isLight
      ? hsl.withLightness(0.15).toColor()
      : hsl.withLightness(0.90).toColor();

  final base = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
    contrastLevel: contrast.seedContrastLevel,
  );

  return base.copyWith(
    primary: accent,
    onPrimary: _onAccent(accent),
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: accent,
    onSecondary: _onAccent(accent),
    secondaryContainer: primaryContainer,
    onSecondaryContainer: onPrimaryContainer,
  );
}

/// The least change of [color]'s lightness that holds [ratio] against every
/// surface of [scheme]: measured against `surfaceContainerHighest`, the
/// surface furthest from it in either brightness.
Color _legible(Color color,
    {required ColorScheme scheme, required double ratio}) {
  final background = scheme.surfaceContainerHighest;
  final lb = background.computeLuminance();
  double contrast(Color c) {
    final lc = c.computeLuminance();
    return (math.max(lc, lb) + 0.05) / (math.min(lc, lb) + 0.05);
  }

  final darken = lb > 0.179;
  var hsl = HSLColor.fromColor(color);
  while (contrast(hsl.toColor()) < ratio) {
    final next = darken ? hsl.lightness - 0.01 : hsl.lightness + 0.01;
    if (next <= 0 || next >= 1) return darken ? Colors.black : Colors.white;
    hsl = hsl.withLightness(next);
  }
  return hsl.toColor();
}

/// WCAG AA for text under 24 px (18.66 px bold).
const double _textRatio = 4.5;

/// WCAG AA for a non-text indicator of state.
const double _indicatorRatio = 3.0;

/// Colours Material's roles do not name, each held to the contrast its use
/// needs on every surface (A11Y-010).
extension ContrastRoles on ColorScheme {
  /// The accent as text on a surface: a section header, a link-like label.
  /// `primary` itself is a fill, at 1.56:1 on white for the green accent.
  Color get accentText =>
      _legible(primary, scheme: this, ratio: _textRatio);

  /// The accent as a state on a surface: a switch track that is on, a
  /// ticked checkbox, a selection border, the current page's dot.
  Color get accentIndicator =>
      _legible(primary, scheme: this, ratio: _indicatorRatio);

  /// What is drawn on [accentIndicator]: a switch thumb, a checkbox's tick.
  Color get onAccentIndicator => _onAccent(accentIndicator);

  /// A warning drawn as text or beside it: a setting that is on without the
  /// data it needs, a cookie the user blocked, a console warning.
  Color get warning =>
      _legible(Colors.orange, scheme: this, ratio: _textRatio);

  /// A good state drawn as text or beside it: a secure cookie, an allowed
  /// request, a user agent that looks valid.
  Color get success =>
      _legible(Colors.green, scheme: this, ratio: _textRatio);

  /// A neutral note drawn as text or beside it: an info log line, a total.
  Color get info => _legible(Colors.blue, scheme: this, ratio: _textRatio);
}
