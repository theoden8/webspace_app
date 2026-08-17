import 'package:flutter/material.dart';

// Accent colors
const Color accentBlue = Color(0xFF6B8DD6);
const Color accentGreen = Color(0xFF7be592);
const Color accentPurple = Color(0xFF9B7BD6);
const Color accentOrange = Color(0xFFE59B5B);
const Color accentRed = Color(0xFFD66B6B);
const Color accentPink = Color(0xFFD66BA8);
const Color accentTeal = Color(0xFF5BC4C4);
const Color accentYellow = Color(0xFFD6C86B);

/// Build a ColorScheme that preserves the full saturation of [accent].
/// Uses fromSeed only for neutral surface/background colors, then overrides
/// all accent-derived roles so nothing gets desaturated by Material 3's HCT.
ColorScheme buildAccentColorScheme(Color accent, Brightness brightness) {
  final bool isLight = brightness == Brightness.light;
  final hsl = HSLColor.fromColor(accent);

  // Container: a tinted but lighter/darker version of the accent
  final primaryContainer = isLight
      ? hsl.withLightness((hsl.lightness * 0.3 + 0.7).clamp(0.80, 0.92)).withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0)).toColor()
      : hsl.withLightness((hsl.lightness * 0.35).clamp(0.12, 0.25)).withSaturation((hsl.saturation * 0.8).clamp(0.0, 1.0)).toColor();

  final onPrimaryContainer = isLight
      ? hsl.withLightness(0.15).toColor()
      : hsl.withLightness(0.90).toColor();

  // Use fromSeed as base for surface/neutral colors only
  final base = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);

  return base.copyWith(
    primary: accent,
    onPrimary: isLight ? Colors.white : Colors.black,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: accent,
    onSecondary: isLight ? Colors.white : Colors.black,
    secondaryContainer: primaryContainer,
    onSecondaryContainer: onPrimaryContainer,
  );
}
