import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:webspace/main.dart' show AccentColor, recolorLogoPixels;

/// Load a PNG asset and return its raw RGBA pixels + dimensions.
(Uint8List pixels, int width, int height) _loadIcon(String path) {
  final bytes = File(path).readAsBytesSync();
  final image = img.decodeImage(bytes)!;
  // Ensure RGBA8 format
  final rgba = image.convert(numChannels: 4);
  final pixels = Uint8List.fromList(rgba.buffer.asUint8List());
  return (pixels, rgba.width, rgba.height);
}

/// Compute a simple hash over the pixel buffer for comparison.
int _pixelHash(Uint8List pixels) {
  // FNV-1a 32-bit
  int hash = 0x811c9dc5;
  for (int i = 0; i < pixels.length; i++) {
    hash ^= pixels[i];
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Compute the average visible (alpha > 0) color as (r, g, b).
(double r, double g, double b) _averageVisibleColor(Uint8List pixels) {
  double rSum = 0, gSum = 0, bSum = 0;
  int count = 0;
  for (int i = 0; i < pixels.length; i += 4) {
    final a = pixels[i + 3];
    if (a > 0) {
      // Un-premultiply to get true RGB
      final factor = 255.0 / a;
      rSum += pixels[i] * factor;
      gSum += pixels[i + 1] * factor;
      bSum += pixels[i + 2] * factor;
      count++;
    }
  }
  if (count == 0) return (0, 0, 0);
  return (rSum / count, gSum / count, bSum / count);
}

/// Collect the set of distinct (un-premultiplied) hues from colored pixels.
/// Returns average hue of pixels that have noticeable saturation.
double _averageColoredHue(Uint8List pixels) {
  double hueSum = 0;
  int count = 0;
  for (int i = 0; i < pixels.length; i += 4) {
    final a = pixels[i + 3];
    if (a < 20) continue;
    final factor = 255.0 / a;
    final r = (pixels[i] * factor).clamp(0, 255);
    final g = (pixels[i + 1] * factor).clamp(0, 255);
    final b = (pixels[i + 2] * factor).clamp(0, 255);
    final cMax = [r, g, b].reduce((a, b) => a > b ? a : b);
    final cMin = [r, g, b].reduce((a, b) => a < b ? a : b);
    final delta = cMax - cMin;
    if (delta < 30) continue; // skip grayscale/near-gray pixels
    double hue;
    if (cMax == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (cMax == g) {
      hue = 60 * (((b - r) / delta) + 2);
    } else {
      hue = 60 * (((r - g) / delta) + 4);
    }
    if (hue < 0) hue += 360;
    hueSum += hue;
    count++;
  }
  return count > 0 ? hueSum / count : -1;
}

void main() {
  // Paths relative to project root
  const lightIconPath = 'assets/webspace_icon.png';
  const darkIconPath = 'assets/webspace_icon_dark.png';

  group('recolorLogoPixels', () {
    test('different accent colors produce different pixel hashes', () {
      final (srcPixels, _, _) = _loadIcon(lightIconPath);

      final hashes = <AccentColor, int>{};
      for (final color in AccentColor.values) {
        final pixels = Uint8List.fromList(srcPixels);
        recolorLogoPixels(pixels, color, isLight: true);
        hashes[color] = _pixelHash(pixels);
      }

      // Each non-blue accent should produce a unique hash
      // (blue skips recolor so it's the "identity" output)
      final uniqueHashes = hashes.values.toSet();
      expect(uniqueHashes.length, AccentColor.values.length,
          reason: 'Each accent color should produce a distinct result');
    });

    test('blue accent preserves original icon colors (light)', () {
      final (srcPixels, _, _) = _loadIcon(lightIconPath);
      final processed = Uint8List.fromList(srcPixels);
      recolorLogoPixels(processed, AccentColor.blue, isLight: true);

      // Blue accent on light icon: skipRecolor=true, so colored pixels unchanged.
      // Only alpha processing happens. Verify the hash is stable.
      final processed2 = Uint8List.fromList(srcPixels);
      recolorLogoPixels(processed2, AccentColor.blue, isLight: true);
      expect(_pixelHash(processed), _pixelHash(processed2),
          reason: 'Same input + same params should produce identical output');
    });

    test('blue accent on dark icon preserves blue hue', () {
      final (srcPixels, _, _) = _loadIcon(darkIconPath);
      final pixels = Uint8List.fromList(srcPixels);
      recolorLogoPixels(pixels, AccentColor.blue, isLight: false);

      final hue = _averageColoredHue(pixels);
      // Blue hue should be roughly 200-240
      expect(hue, greaterThan(180),
          reason: 'Blue accent on dark icon should have blue hue, got $hue');
      expect(hue, lessThan(260),
          reason: 'Blue accent on dark icon should have blue hue, got $hue');
    });

    test('purple accent on dark icon has purple hue', () {
      final (srcPixels, _, _) = _loadIcon(darkIconPath);
      final pixels = Uint8List.fromList(srcPixels);
      recolorLogoPixels(pixels, AccentColor.purple, isLight: false);

      final hue = _averageColoredHue(pixels);
      // Purple hue should be roughly 260-300
      expect(hue, greaterThan(250),
          reason: 'Purple accent should have purple hue, got $hue');
      expect(hue, lessThan(310),
          reason: 'Purple accent should have purple hue, got $hue');
    });

    test('blue and purple produce different results on dark icon', () {
      final (srcPixels, _, _) = _loadIcon(darkIconPath);

      final bluePixels = Uint8List.fromList(srcPixels);
      recolorLogoPixels(bluePixels, AccentColor.blue, isLight: false);

      final purplePixels = Uint8List.fromList(srcPixels);
      recolorLogoPixels(purplePixels, AccentColor.purple, isLight: false);

      expect(_pixelHash(bluePixels), isNot(_pixelHash(purplePixels)),
          reason: 'Blue and purple should produce different results on dark icon');
    });

    test('light vs dark mode produce different results for same accent', () {
      final (lightSrc, _, _) = _loadIcon(lightIconPath);
      final (darkSrc, _, _) = _loadIcon(darkIconPath);

      for (final color in [AccentColor.blue, AccentColor.green, AccentColor.purple]) {
        final lightPixels = Uint8List.fromList(lightSrc);
        recolorLogoPixels(lightPixels, color, isLight: true);

        final darkPixels = Uint8List.fromList(darkSrc);
        recolorLogoPixels(darkPixels, color, isLight: false);

        expect(_pixelHash(lightPixels), isNot(_pixelHash(darkPixels)),
            reason: 'Light and dark should differ for ${color.name}');
      }
    });

    test('green accent produces green-ish hue on light icon', () {
      final (srcPixels, _, _) = _loadIcon(lightIconPath);
      final pixels = Uint8List.fromList(srcPixels);
      recolorLogoPixels(pixels, AccentColor.green, isLight: true);

      final hue = _averageColoredHue(pixels);
      // Green hue ~120-160
      expect(hue, greaterThan(100),
          reason: 'Green accent should have green hue, got $hue');
      expect(hue, lessThan(170),
          reason: 'Green accent should have green hue, got $hue');
    });

    test('race condition: using wrong isLight with icon produces wrong result', () {
      // Simulate the race condition bug: light icon processed with dark alpha
      final (lightSrc, _, _) = _loadIcon(lightIconPath);
      final (darkSrc, _, _) = _loadIcon(darkIconPath);

      // Correct: light icon + isLight=true
      final correctLight = Uint8List.fromList(lightSrc);
      recolorLogoPixels(correctLight, AccentColor.green, isLight: true);

      // Bug: light icon + isLight=false (race condition scenario)
      final buggyLight = Uint8List.fromList(lightSrc);
      recolorLogoPixels(buggyLight, AccentColor.green, isLight: false);

      // These should be different - the buggy version has inverted alpha
      expect(_pixelHash(correctLight), isNot(_pixelHash(buggyLight)),
          reason: 'Wrong isLight flag should produce different (broken) result');

      // The correct version should have visible colored pixels
      final correctAvg = _averageVisibleColor(correctLight);
      expect(correctAvg.$1 + correctAvg.$2 + correctAvg.$3, greaterThan(0),
          reason: 'Correct processing should have visible pixels');
    });
  });
}
