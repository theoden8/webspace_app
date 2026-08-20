// Do the token values themselves still make sense?
//
// The no-literals guard (test/js/design_tokens_no_literals.test.js) proves the
// widgets read the tokens. It says nothing about what is in them, so a
// designer editing design_tokens.dart can produce a file that compiles, passes
// every existing test, and is wrong: a radius scale that is no longer a scale,
// a chrome bar darker in light mode than in dark, a padlock invisible against
// the bar it sits on, an icon larger than the target that holds it.
//
// Everything here is a relationship between values rather than a value itself,
// so retuning the palette is free and inverting the design is not.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/theme/design_tokens.dart';

/// CIE76 colour difference. Luminance contrast is the wrong instrument for
/// "are these two indicators telling me different things": green 700 and grey
/// 600 sit within 1.12:1 of each other by construction, because they differ in
/// hue rather than in lightness.
double _deltaE(Color a, Color b) {
  List<double> lab(Color c) {
    double linear(double v) =>
        v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
    final r = linear(c.r), g = linear(c.g), bl = linear(c.b);
    // sRGB -> XYZ (D65), then XYZ -> L*a*b*.
    final x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047;
    final y = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
    final z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883;
    double f(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3).toDouble() : 7.787 * t + 16 / 116;
    final fx = f(x), fy = f(y), fz = f(z);
    return [116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)];
  }

  final la = lab(a), lb = lab(b);
  return math.sqrt(math.pow(la[0] - lb[0], 2) +
      math.pow(la[1] - lb[1], 2) +
      math.pow(la[2] - lb[2], 2));
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void _ascending(List<double> values, String what) {
  for (var i = 1; i < values.length; i++) {
    expect(values[i], greaterThan(values[i - 1]),
        reason: '$what is not a scale: ${values[i]} follows ${values[i - 1]}');
  }
}

void main() {
  group('Radii', () {
    test('is a strictly ascending scale of positive values', () {
      _ascending(Radii.scale, 'Radii.scale');
      for (final r in Radii.scale) {
        expect(r, greaterThan(0));
        expect(r.isFinite, isTrue);
      }
    });

    test('the scale is exactly the named steps, in order', () {
      // The gallery's radius card renders Radii.scale. A step added as a
      // constant but not to the scale is invisible there and untested here.
      expect(Radii.scale, [Radii.xs, Radii.sm, Radii.md, Radii.lg, Radii.xl]);
      expect(Radii.scale.toSet().length, Radii.scale.length);
    });
  });

  group('Spacing', () {
    test('is a strictly ascending scale on a 4pt grid', () {
      final scale = [Spacing.xs, Spacing.sm, Spacing.md, Spacing.lg, Spacing.xl];
      _ascending(scale, 'Spacing');
      for (final s in scale) {
        expect(s, greaterThan(0));
        expect(s % 4, 0, reason: '$s is off the 4pt grid');
      }
    });
  });

  group('Chrome', () {
    test('bars are opaque and the light one is actually lighter', () {
      for (final c in [Chrome.barLight, Chrome.barDark, Chrome.hairlineLight, Chrome.hairlineDark]) {
        expect(c.a, 1.0, reason: 'chrome must be opaque; web content shows through otherwise');
      }
      expect(Chrome.barLight.computeLuminance(), greaterThan(0.5));
      expect(Chrome.barDark.computeLuminance(), lessThan(0.5));
      expect(Chrome.bar(false), Chrome.barLight);
      expect(Chrome.bar(true), Chrome.barDark);
    });

    test('each hairline separates from its bar without becoming a border', () {
      for (final isDark in [false, true]) {
        final ratio = _contrast(Chrome.bar(isDark), Chrome.hairline(isDark));
        expect(ratio, greaterThan(1.05),
            reason: '${isDark ? 'dark' : 'light'} hairline is invisible on its bar');
        expect(ratio, lessThan(3.0),
            reason: '${isDark ? 'dark' : 'light'} hairline reads as a drawn border, not a seam');
      }
    });

    test('the hairline is hairline-width', () {
      expect(Chrome.hairlineWidth, greaterThan(0));
      expect(Chrome.hairlineWidth, lessThanOrEqualTo(1));
    });
  });

  test('the padlock stays visible on both chrome bars', () {
    // WCAG 1.4.11: a non-text indicator carrying meaning needs 3:1 against
    // what it sits on. The padlock is the only security signal in the URL bar.
    for (final colour in [SecurityIndicator.secure, SecurityIndicator.insecure]) {
      for (final isDark in [false, true]) {
        final ratio = _contrast(colour, Chrome.bar(isDark));
        expect(ratio, greaterThanOrEqualTo(3.0),
            reason: 'padlock at ${ratio.toStringAsFixed(2)}:1 on the '
                '${isDark ? 'dark' : 'light'} bar');
      }
    }
    // 20 is comfortably past "different colour" and well short of demanding a
    // particular pair; ~49 today.
    expect(_deltaE(SecurityIndicator.secure, SecurityIndicator.insecure),
        greaterThan(20),
        reason: 'secure and insecure must not read as the same colour');
  });

  group('Sizing', () {
    test('icon sizes ascend and stay legible', () {
      _ascending([IconSizes.inline, IconSizes.action, IconSizes.floating], 'IconSizes');
      expect(IconSizes.inline, greaterThanOrEqualTo(12));
      expect(IconSizes.floating, lessThanOrEqualTo(48));
    });

    test('a tap target is at least as big as the icon it holds', () {
      expect(TapTargets.compact, greaterThanOrEqualTo(IconSizes.action));
      // Material's own floor is 48; this token is the documented exception for
      // compact icon buttons, and 32 is as small as that exception goes.
      expect(TapTargets.compact, greaterThanOrEqualTo(32));
    });

    test('the URL text is readable', () {
      expect(TextSizes.url, greaterThanOrEqualTo(12));
      expect(TextSizes.url, lessThanOrEqualTo(20));
    });
  });

  test('press feedback is quick enough to feel attached to the finger', () {
    expect(Motion.press.inMilliseconds, greaterThanOrEqualTo(50));
    expect(Motion.press.inMilliseconds, lessThanOrEqualTo(300));
  });

  test('the floating button reads as floating', () {
    expect(Elevations.floating, greaterThan(0));
    expect(Elevations.floatingActive, greaterThan(Elevations.floating),
        reason: 'the dragged button must lift above its resting state');
    expect(FloatingButton.surfaceOpacity, greaterThan(0.5),
        reason: 'below this the button stops reading as a control');
    expect(FloatingButton.surfaceOpacity, lessThanOrEqualTo(1.0));
    expect(FloatingButton.dragScale, greaterThan(1.0));
    expect(FloatingButton.dragScale, lessThanOrEqualTo(2.0));
    expect(FloatingButton.padding, greaterThan(0));
  });

  test('security state is not signalled by colour alone', () {
    // WCAG 1.4.1. The padlock is 16px of solid colour; deuteranopia collapses
    // the green/grey pair, and a colour-only signal then reads as secure on a
    // plain http page. The icon must change too, so the shape carries it.
    final source = File('lib/widgets/url_bar.dart').readAsStringSync();
    expect(source, contains('Icons.lock_open'),
        reason: 'the insecure state needs its own icon, not just its own colour');
    expect(RegExp(r'isSecure \?\s*Icons\.lock\s*:\s*Icons\.lock_open').hasMatch(source),
        isTrue,
        reason: 'the padlock icon must branch on the same condition as its colour');
  });
}
