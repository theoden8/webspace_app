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
import 'package:webspace/theme/app_theme.dart';

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
double contrastRatio(Color a, {required Color b}) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

// WCAG AA for normal-size text.
const double _minRatio = 4.5;

// WCAG AA for a non-text indicator of state.
const double _indicatorRatio = 3.0;

// WCAG AAA, which the high contrast theme holds its neutral text to.
const double _highRatio = 7.0;

void main() {
  test('every accent keeps AA contrast on its paired on-colours (DESIGN-007)', () {
    final failures = <String>[];

    for (final (contrast, brightness) in [
      for (final c in ThemeContrast.values)
        for (final b in Brightness.values) (c, b),
    ]) {
      for (final accent in _accents.entries) {
        final s = buildAccentColorScheme(accent.value,
            brightness: brightness, contrast: contrast);
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
          final ratio = contrastRatio(pair.value[0], b: pair.value[1]);
          if (ratio < _minRatio) {
            failures.add('${contrast.name} ${brightness.name} ${accent.key} ${pair.key}: '
                '${ratio.toStringAsFixed(2)}:1');
          }
        }
      }
    }

    expect(failures, isEmpty, reason: 'below ${_minRatio}:1:\n${failures.join('\n')}');
  });

  test('text roles keep AA contrast on every surface, in both contrasts (A11Y-010)', () {
    final failures = <String>[];

    for (final contrast in ThemeContrast.values) {
      for (final brightness in Brightness.values) {
        for (final accent in _accents.entries) {
          final theme = buildAppTheme(accent.value,
              brightness: brightness, contrast: contrast);
          final s = theme.colorScheme;
          final texts = <String, Color>{
            'accentText': s.accentText,
            'warning': s.warning,
            'success': s.success,
            'info': s.info,
            'error': s.error,
            'onSurfaceVariant': s.onSurfaceVariant,
          };
          final grounds = <String, Color>{
            'scaffold': theme.scaffoldBackgroundColor,
            'surface': s.surface,
            'surfaceContainerHighest': s.surfaceContainerHighest,
          };
          for (final text in texts.entries) {
            for (final ground in grounds.entries) {
              final ratio = contrastRatio(text.value, b: ground.value);
              if (ratio < _minRatio) {
                failures.add('${contrast.name} ${brightness.name} '
                    '${accent.key} ${text.key}/${ground.key}: '
                    '${ratio.toStringAsFixed(2)}:1');
              }
            }
          }
        }
      }
    }

    expect(failures, isEmpty, reason: 'below $_minRatio:1:\n${failures.join('\n')}');
  });

  test('indicators keep 3:1 on every surface, in both contrasts (A11Y-010)', () {
    final failures = <String>[];

    for (final contrast in ThemeContrast.values) {
      for (final brightness in Brightness.values) {
        for (final accent in _accents.entries) {
          final theme = buildAppTheme(accent.value,
              brightness: brightness, contrast: contrast);
          final s = theme.colorScheme;
          final checks = <String, (Color, Color)>{
            'accentIndicator/scaffold': (s.accentIndicator, theme.scaffoldBackgroundColor),
            'accentIndicator/surface': (s.accentIndicator, s.surface),
            'accentIndicator/surfaceContainerHighest':
                (s.accentIndicator, s.surfaceContainerHighest),
            'outline/surface': (s.outline, s.surface),
          };
          for (final check in checks.entries) {
            final (a, b) = check.value;
            final ratio = contrastRatio(a, b: b);
            if (ratio < _indicatorRatio) {
              failures.add('${contrast.name} ${brightness.name} '
                  '${accent.key} ${check.key}: ${ratio.toStringAsFixed(2)}:1');
            }
          }
          final onRatio = contrastRatio(s.onAccentIndicator, b: s.accentIndicator);
          if (onRatio < _minRatio) {
            failures.add('${contrast.name} ${brightness.name} ${accent.key} '
                'onAccentIndicator/accentIndicator: ${onRatio.toStringAsFixed(2)}:1');
          }
        }
      }
    }

    expect(failures, isEmpty, reason: 'below the floor:\n${failures.join('\n')}');
  });

  test('a switch, checkbox or radio that is on draws the indicator role '
      '(A11Y-010)', () {
    const on = {WidgetState.selected};
    const onDisabled = {WidgetState.selected, WidgetState.disabled};
    for (final contrast in ThemeContrast.values) {
      for (final brightness in Brightness.values) {
        for (final accent in _accents.entries) {
          final theme = buildAppTheme(accent.value,
              brightness: brightness, contrast: contrast);
          final s = theme.colorScheme;
          final why = '${accent.key} ${brightness.name} ${contrast.name}';
          expect(theme.switchTheme.trackColor!.resolve(on), s.accentIndicator,
              reason: why);
          expect(theme.switchTheme.thumbColor!.resolve(on), s.onAccentIndicator,
              reason: why);
          expect(theme.checkboxTheme.fillColor!.resolve(on), s.accentIndicator,
              reason: why);
          expect(theme.radioTheme.fillColor!.resolve(on), s.accentIndicator,
              reason: why);
          expect(theme.switchTheme.trackColor!.resolve(onDisabled), isNull,
              reason: '$why: a disabled switch keeps Material\'s colours');
          expect(theme.switchTheme.trackColor!.resolve(const {}), isNull,
              reason: '$why: an off switch keeps Material\'s colours');
        }
      }
    }
  });

  testWidgets('a Switch that is on paints its track in the indicator role '
      '(A11Y-010)', (tester) async {
    final theme = buildAppTheme(accentGreen, brightness: Brightness.light);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: Material(child: Switch(value: true, onChanged: (_) {})),
    ));
    expect(
      find.byType(Switch),
      paints..rrect(color: theme.colorScheme.accentIndicator),
    );
  });

  test('accentText keeps the accent where it already reads (A11Y-010)', () {
    // Where the accent already holds 4.5:1 it is drawn as it is; elsewhere
    // only its lightness moves.
    for (final brightness in Brightness.values) {
      for (final accent in _accents.entries) {
        final s = buildAccentColorScheme(accent.value, brightness: brightness);
        if (contrastRatio(s.primary, b: s.surfaceContainerHighest) >= _minRatio) {
          expect(s.accentText, s.primary, reason: '${accent.key} ${brightness.name}');
        } else {
          expect(HSLColor.fromColor(s.accentText).hue,
              closeTo(HSLColor.fromColor(s.primary).hue, 1.0),
              reason: '${accent.key} ${brightness.name} keeps its hue');
        }
      }
    }
  });

  test('the high contrast theme holds neutral text to 7:1 (A11Y-010)', () {
    for (final brightness in Brightness.values) {
      for (final accent in _accents.entries) {
        final s = buildAccentColorScheme(accent.value,
            brightness: brightness, contrast: ThemeContrast.high);
        for (final text in [s.onSurface, s.onSurfaceVariant]) {
          expect(contrastRatio(text, b: s.surface), greaterThanOrEqualTo(_highRatio),
              reason: '${accent.key} ${brightness.name}');
        }
      }
    }
  });

  test('the accent survives into primary undesaturated', () {
    for (final contrast in ThemeContrast.values) {
      for (final brightness in Brightness.values) {
        for (final accent in _accents.entries) {
          final s = buildAccentColorScheme(accent.value,
              brightness: brightness, contrast: contrast);
          final why = '${accent.key} ${brightness.name} ${contrast.name}';
          expect(s.primary, accent.value, reason: why);
          expect(s.secondary, accent.value, reason: why);
        }
      }
    }
  });

  test('on-colour tracks the accent, not the theme brightness', () {
    // The light accents need dark labels in both themes; picking by
    // Brightness alone is what this guards against.
    for (final name in ['green', 'yellow', 'teal', 'orange']) {
      final accent = _accents[name]!;
      final light =
          buildAccentColorScheme(accent, brightness: Brightness.light);
      final dark = buildAccentColorScheme(accent, brightness: Brightness.dark);
      expect(light.onPrimary, dark.onPrimary, reason: name);
    }
  });
}
