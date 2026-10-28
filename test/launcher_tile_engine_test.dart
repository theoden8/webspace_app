import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/launcher_tile_engine.dart';

/// A [size] square icon: a disc of [disc] on transparency, with a [hole] cut
/// out of its middle (GitHub's logo is a disc with the cat cut out) or an
/// opaque [glyph] drawn there (Discord's is a disc with a white glyph).
img.Image _discIcon({
  required img.Color disc,
  bool hole = false,
  img.Color? glyph,
  int size = 64,
}) {
  final icon = img.Image(width: size, height: size, numChannels: 4)
    ..clear(img.ColorRgba8(0, 0, 0, 0));
  final c = size / 2;
  for (final p in icon) {
    final dx = p.x + 0.5 - c;
    final dy = p.y + 0.5 - c;
    if (math.sqrt(dx * dx + dy * dy) > c) continue;
    final inMiddle = dx.abs() < size / 6 && dy.abs() < size / 6;
    if (inMiddle && hole) continue;
    p.set(inMiddle && glyph != null ? glyph : disc);
  }
  return icon;
}

img.Color _rgb(int hex) =>
    img.ColorRgba8((hex >> 16) & 0xFF, (hex >> 8) & 0xFF, hex & 0xFF, 0xFF);

img.Image _tileOf(img.Image icon) =>
    img.decodePng(launcherTileIcon(img.encodePng(icon))!)!;

bool _isPlate(img.Pixel p, {required TilePlate plate}) =>
    p.r == plate.r && p.g == plate.g && p.b == plate.b && p.a == 0xFF;

void main() {
  final white = _rgb(0xFFFFFF);
  final githubInk = _rgb(0x24292E);

  group('plateFor (HS-018)', () {
    test('a white logo on transparency takes the dark plate', () {
      expect(plateFor(_discIcon(disc: white, hole: true)), TilePlate.dark);
    });

    test('a dark logo on transparency takes the light plate', () {
      expect(plateFor(_discIcon(disc: githubInk, hole: true)), TilePlate.light);
    });

    test('a coloured disc keeps the light plate whatever its glyph', () {
      final discord = _discIcon(disc: _rgb(0x5865F2), glyph: white);
      expect(plateFor(discord), TilePlate.light);
    });

    test('a near-white logo takes the dark plate', () {
      expect(plateFor(_discIcon(disc: _rgb(0xF0F0F0))), TilePlate.dark);
    });

    test('a white logo with a small coloured mark is still lost on white', () {
      final marked = _discIcon(disc: white, size: 96);
      img.fillRect(
        marked,
        x1: 44,
        y1: 44,
        x2: 51,
        y2: 51,
        color: _rgb(0x2185D0),
      );
      expect(plateFor(marked), TilePlate.dark);
    });

    // Pale brand colours (Hugging Face's yellow, CoinGecko's green) show on
    // the white the launcher wraps them in today, and keep it.
    test('a pale yellow icon keeps the light plate', () {
      expect(plateFor(_discIcon(disc: _rgb(0xFFD21E))), TilePlate.light);
    });

    test('a mid grey keeps the light plate', () {
      expect(plateFor(_discIcon(disc: _rgb(0x777777))), TilePlate.light);
    });

    test('a white background of the icon\'s own keeps the light plate', () {
      final opaque = img.Image(width: 32, height: 32)..clear(white);
      img.fillRect(opaque, x1: 8, y1: 8, x2: 23, y2: 23, color: _rgb(0x000000));
      expect(opaque.numChannels, 3);
      expect(plateFor(opaque), TilePlate.light);
    });

    test('a fully transparent icon takes the light plate', () {
      final empty = img.Image(width: 32, height: 32, numChannels: 4)
        ..clear(img.ColorRgba8(255, 255, 255, 0));
      expect(plateFor(empty), TilePlate.light);
    });
  });

  group('launcherTileIcon (HS-018)', () {
    test('a white logo is drawn on the dark plate, opaque to the edge', () {
      final tile = _tileOf(_discIcon(disc: white, hole: true));
      expect((tile.width, tile.height), (kLauncherTileEdge, kLauncherTileEdge));
      expect(
        tile.every((p) => p.a == 0xFF),
        isTrue,
        reason:
            'A pixel with any transparency lets the launcher\'s own '
            'background through.',
      );
      for (final (x, y) in [
        (0, 0),
        (kLauncherTileEdge - 1, 0),
        (0, kLauncherTileEdge - 1),
        (kLauncherTileEdge - 1, kLauncherTileEdge - 1),
      ]) {
        expect(_isPlate(tile.getPixel(x, y), plate: TilePlate.dark), isTrue);
      }
      final logo = tile.where((p) => p.r == 0xFF && p.g == 0xFF && p.b == 0xFF);
      expect(
        logo.length,
        greaterThan(kLauncherTileIconBox * 10),
        reason: 'The white logo is drawn, not lost in the plate.',
      );
    });

    test('a dark logo is drawn on the light plate', () {
      final tile = _tileOf(_discIcon(disc: githubInk, hole: true));
      expect(_isPlate(tile.getPixel(0, 0), plate: TilePlate.light), isTrue);
      expect(
        tile.where((p) => p.r == 0x24 && p.g == 0x29 && p.b == 0x2E).length,
        greaterThan(kLauncherTileIconBox * 10),
      );
    });

    test('the icon stays inside the safe zone no launcher mask cuts', () {
      // An opaque square fills its box to the corners, the worst case.
      final red = img.Image(width: 48, height: 48)..clear(_rgb(0xFF0000));
      final tile = _tileOf(red);
      final centre = kLauncherTileEdge / 2;
      final safeRadius = kLauncherTileEdge * 33 / 108;
      var drawn = 0;
      for (final p in tile) {
        final dx = p.x + 0.5 - centre;
        final dy = p.y + 0.5 - centre;
        if (_isPlate(p, plate: TilePlate.light)) continue;
        drawn++;
        expect(
          math.sqrt(dx * dx + dy * dy),
          lessThanOrEqualTo(safeRadius),
          reason: 'pixel (${p.x}, ${p.y}) is outside the safe zone',
        );
      }
      expect(
        drawn,
        greaterThan(kLauncherTileIconBox * kLauncherTileIconBox ~/ 2),
      );
    });

    test('a wide icon keeps its aspect ratio', () {
      final wide = img.Image(width: 64, height: 32)..clear(_rgb(0x0000FF));
      final tile = _tileOf(wide);
      final drawn = tile.where((p) => !_isPlate(p, plate: TilePlate.light));
      final xs = drawn.map((p) => p.x);
      final ys = drawn.map((p) => p.y);
      final w = xs.reduce(math.max) - xs.reduce(math.min) + 1;
      final h = ys.reduce(math.max) - ys.reduce(math.min) + 1;
      expect(w, kLauncherTileIconBox);
      expect(h, closeTo(kLauncherTileIconBox / 2, 1));
    });

    test('scaling blends the logo with the plate, not with black', () {
      // Transparent pixels hold black; scaled before flattening, the edge
      // of a pale logo on the light plate would pick up a dark fringe.
      final grey = _discIcon(disc: _rgb(0x888888), size: 32);
      final tile = _tileOf(grey);
      expect(
        tile.every((p) => p.r >= 0x88 && p.g >= 0x88 && p.b >= 0x88),
        isTrue,
      );
    });

    test('bytes that do not decode give no tile', () {
      expect(launcherTileIcon(Uint8List.fromList([1, 2, 3, 4])), isNull);
    });
  });
}
