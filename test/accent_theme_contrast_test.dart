// Contrast floor for every accent the user can pick.
//
// buildAccentColorScheme overrides the seed-derived roles to keep the accent
// saturated, which means Material 3 is no longer guaranteeing legibility of
// the paired on-colours; nothing else checks them. Tying onPrimary to the
// theme's brightness rather than to the accent put white on 0xFF7be592 green
// at 1.56:1.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/theme/accent_theme.dart';

const Map<String, Color> _accents = {
  'blue': accentBlue,
  'green': accentGreen,
  'purple': accentPurple,
  'orange': accentOrange,
  'red': accentRed,
  'pink': accentPink,
  'teal': accentTeal,
  'yellow': accentYellow,
};

/// WCAG 2.1 contrast ratio, 1.0 (identical) to 21.0 (black on white).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

// WCAG AA for normal-size text.
const double _minRatio = 4.5;

void main() {
  test('every accent keeps AA contrast on its paired on-colours', () {
    final failures = <String>[];

    for (final brightness in Brightness.values) {
      for (final accent in _accents.entries) {
        final s = buildAccentColorScheme(accent.value, brightness);
        final pairs = <String, List<Color>>{
          'primary/onPrimary': [s.primary, s.onPrimary],
          'secondary/onSecondary': [s.secondary, s.onSecondary],
          'primaryContainer/onPrimaryContainer': [s.primaryContainer, s.onPrimaryContainer],
          'secondaryContainer/onSecondaryContainer': [s.secondaryContainer, s.onSecondaryContainer],
          'surface/onSurface': [s.surface, s.onSurface],
          'surfaceContainerHighest/onSurfaceVariant': [s.surfaceContainerHighest, s.onSurfaceVariant],
          'error/onError': [s.error, s.onError],
        };
        for (final pair in pairs.entries) {
          final ratio = contrastRatio(pair.value[0], pair.value[1]);
          if (ratio < _minRatio) {
            failures.add('${brightness.name} ${accent.key} ${pair.key}: '
                '${ratio.toStringAsFixed(2)}:1');
          }
        }
      }
    }

    expect(failures, isEmpty, reason: 'below ${_minRatio}:1:\n${failures.join('\n')}');
  });

  test('the accent survives into primary undesaturated', () {
    for (final brightness in Brightness.values) {
      for (final accent in _accents.entries) {
        final s = buildAccentColorScheme(accent.value, brightness);
        expect(s.primary, accent.value, reason: '${accent.key} ${brightness.name}');
        expect(s.secondary, accent.value, reason: '${accent.key} ${brightness.name}');
      }
    }
  });

  test('on-colour tracks the accent, not the theme brightness', () {
    // The light accents need dark labels in both themes; picking by
    // Brightness alone is what this guards against.
    for (final name in ['green', 'yellow', 'teal', 'orange']) {
      final accent = _accents[name]!;
      final light = buildAccentColorScheme(accent, Brightness.light);
      final dark = buildAccentColorScheme(accent, Brightness.dark);
      expect(light.onPrimary, dark.onPrimary, reason: name);
    }
  });
}
