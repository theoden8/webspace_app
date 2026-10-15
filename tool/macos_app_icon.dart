import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Writes the macOS app icon set from the square artwork every platform shares.
///
/// iOS and Android cut their own shape out of a square icon; macOS draws the
/// PNG as it is, so the shape is baked in here: Apple's template, an 824 px
/// continuous-corner square with a drop shadow, centred on a 1024 px canvas.
/// macOS 26 shrinks an icon that does not fit that shape onto a grey tile.
///
/// The macOS build runs this (the Runner target's "Generate App Icon" phase)
/// whenever the artwork or this file changes; the set it writes is committed.
void main() {
  final square = img.decodePng(File(_source).readAsBytesSync())!;
  final art = img.copyResize(
    square,
    width: _body,
    height: _body,
    interpolation: img.Interpolation.average,
  );
  final canvas = _compose(art);
  for (final size in macosIconSizes) {
    File(
      '$macosIconSet/app_icon_$size.png',
    ).writeAsBytesSync(img.encodePng(_downscale(canvas, size: size)));
  }
}

const macosIconSet = 'macos/Runner/Assets.xcassets/AppIcon.appiconset';
const macosIconSizes = [16, 32, 64, 128, 256, 512, 1024];

const _source = 'assets/webspace_icon.png';
const _canvas = 1024;
const _margin = 100;
const _body = 824;
const _radius = 185.4;
const _shadowOffset = 12;
const _shadowSigma = 14.0; // the template's 28 px blur
const _shadowOpacity = 0.5;

/// Apple's continuous corner for a radius of 1, as Bézier segments of
/// (inset from the side, inset from the top), from where it leaves the top
/// edge to where it meets the side. The values are PaintCode's measurement of
/// the iOS icon shape (paintcodeapp.com, "Code for iOS 7 rounded rectangles").
const _corner = [
  [
    (1.52866471, 0.0),
    (1.08849323, 0.0),
    (0.86840689, 0.0),
    (0.66993427, 0.06549600),
  ],
  [(0.66993427, 0.06549600), (0.63149399, 0.07491100)],
  [
    (0.63149399, 0.07491100),
    (0.37282392, 0.16905899),
    (0.16906013, 0.37282401),
    (0.07491176, 0.63149399),
  ],
  [
    (0.07491176, 0.63149399),
    (0.0, 0.86840701),
    (0.0, 1.08849299),
    (0.0, 1.52866483),
  ],
];

/// The body's coverage of each pixel of an 824 px square, from 16 scanlines
/// per row.
Float64List _bodyCoverage() {
  const steps = 64;
  final curve = <(double, double)>[
    for (final c in _corner)
      for (var i = 0; i <= steps; i++) _bezier(c, t: i / steps),
  ];
  double insetAt(double fromEdge) {
    for (var i = 1; i < curve.length; i++) {
      final (x0, y0) = curve[i - 1];
      final (x1, y1) = curve[i];
      if (fromEdge <= y1 * _radius) {
        final f = y1 == y0 ? 0.0 : (fromEdge / _radius - y0) / (y1 - y0);
        return (x0 + (x1 - x0) * f) * _radius;
      }
    }
    return 0;
  }

  const rows = 16;
  final coverage = Float64List(_body * _body);
  for (var y = 0; y < _body; y++) {
    for (var s = 0; s < rows; s++) {
      final at = y + (s + 0.5) / rows;
      final inset = insetAt(math.min(at, _body - at));
      for (var x = 0; x < _body; x++) {
        final overlap =
            math.min(x + 1, _body - inset) - math.max(x.toDouble(), inset);
        if (overlap > 0) coverage[y * _body + x] += math.min(overlap, 1) / rows;
      }
    }
  }
  return coverage;
}

(double, double) _bezier(List<(double, double)> c, {required double t}) {
  var p = c;
  while (p.length > 1) {
    p = [
      for (var i = 1; i < p.length; i++)
        (
          p[i - 1].$1 + (p[i].$1 - p[i - 1].$1) * t,
          p[i - 1].$2 + (p[i].$2 - p[i - 1].$2) * t,
        ),
    ];
  }
  return p.single;
}

/// The 1024 px icon as premultiplied RGBA in 0..1.
Float64List _compose(img.Image art) {
  final body = _bodyCoverage();
  final shadow = Float64List(_canvas * _canvas);
  for (var y = 0; y < _body; y++) {
    for (var x = 0; x < _body; x++) {
      shadow[(y + _margin + _shadowOffset) * _canvas + x + _margin] =
          body[y * _body + x];
    }
  }
  _blur(shadow);

  final out = Float64List(_canvas * _canvas * 4);
  for (var y = 0; y < _canvas; y++) {
    for (var x = 0; x < _canvas; x++) {
      final bx = x - _margin, by = y - _margin;
      final inBody = bx >= 0 && bx < _body && by >= 0 && by < _body;
      final a = inBody ? body[by * _body + bx] : 0.0;
      final i = (y * _canvas + x) * 4;
      if (a > 0) {
        final p = art.getPixel(bx, by);
        out[i] = p.rNormalized.toDouble() * a;
        out[i + 1] = p.gNormalized.toDouble() * a;
        out[i + 2] = p.bNormalized.toDouble() * a;
      }
      out[i + 3] = a + shadow[y * _canvas + x] * _shadowOpacity * (1 - a);
    }
  }
  return out;
}

void _blur(Float64List field) {
  final reach = (_shadowSigma * 3).ceil();
  final kernel = [
    for (var d = -reach; d <= reach; d++)
      math.exp(-d * d / (2 * _shadowSigma * _shadowSigma)),
  ];
  final total = kernel.reduce((a, b) => a + b);
  final row = Float64List(_canvas);
  for (final (stride, step) in [(_canvas, 1), (1, _canvas)]) {
    for (var line = 0; line < _canvas; line++) {
      for (var k = 0; k < _canvas; k++) {
        var sum = 0.0;
        final last = math.min(k + reach, _canvas - 1);
        for (var j = math.max(k - reach, 0); j <= last; j++) {
          sum += kernel[j - k + reach] * field[line * stride + j * step];
        }
        row[k] = sum / total;
      }
      for (var k = 0; k < _canvas; k++) {
        field[line * stride + k * step] = row[k];
      }
    }
  }
}

/// Box-filters the premultiplied canvas down to [size] and un-premultiplies,
/// so the body's edge does not average with the black of transparent pixels.
img.Image _downscale(Float64List canvas, {required int size}) {
  final f = _canvas ~/ size;
  final out = img.Image(width: size, height: size, numChannels: 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final sum = [0.0, 0.0, 0.0, 0.0];
      for (var dy = 0; dy < f; dy++) {
        for (var dx = 0; dx < f; dx++) {
          final i = ((y * f + dy) * _canvas + x * f + dx) * 4;
          for (var c = 0; c < 4; c++) {
            sum[c] += canvas[i + c];
          }
        }
      }
      final a = sum[3] / (f * f);
      int channel(int c) =>
          a == 0 ? 0 : (sum[c] / (f * f) / a * 255).round().clamp(0, 255);
      out.setPixelRgba(
        x,
        y,
        channel(0),
        channel(1),
        channel(2),
        (a * 255).round().clamp(0, 255),
      );
    }
  }
  return out;
}
