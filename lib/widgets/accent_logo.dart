import 'dart:async';
import 'dart:math' show min, max;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/theme/app_theme.dart';


/// Recolor RGBA pixel buffer in-place for logo display.
/// Exported for testing.
void recolorLogoPixels(Uint8List pixels,
    {required AccentColor accentColor, required bool isLight}) {
  final accent = accentColor.color;
  final skipRecolor = accentColor == AccentColor.blue;

  for (int i = 0; i < pixels.length; i += 4) {
    final c0 = pixels[i];
    final c1 = pixels[i + 1];
    final c2 = pixels[i + 2];

    final cMin = min(c0, min(c1, c2));
    final cMax = max(c0, max(c1, c2));

    // Compute alpha: map background to transparent, content to opaque,
    // with smooth falloff in between to anti-alias edges cleanly.
    int alpha;
    if (isLight) {
      if (cMin >= 200) {
        alpha = 0;
      } else if (cMin <= 100) {
        alpha = 255;
      } else {
        alpha = 255 * (200 - cMin) ~/ 100;
      }
    } else {
      if (cMax <= 55) {
        alpha = 0;
      } else if (cMax >= 155) {
        alpha = 255;
      } else {
        alpha = 255 * (cMax - 55) ~/ 100;
      }
    }

    int r = c0, g = c1, b = c2;

    // Recolor blue pixels to accent (skip for blue accent)
    if (!skipRecolor && alpha > 0 && cMax - cMin > 40 && cMax > 60) {
      r = accent.red;
      g = accent.green;
      b = accent.blue;
    }

    // Premultiply: Skia/Impeller expect premultiplied RGBA
    if (alpha == 0) {
      pixels[i] = 0;
      pixels[i + 1] = 0;
      pixels[i + 2] = 0;
      pixels[i + 3] = 0;
    } else if (alpha < 255) {
      pixels[i] = (r * alpha) ~/ 255;
      pixels[i + 1] = (g * alpha) ~/ 255;
      pixels[i + 2] = (b * alpha) ~/ 255;
      pixels[i + 3] = alpha;
    } else {
      pixels[i] = r;
      pixels[i + 1] = g;
      pixels[i + 2] = b;
      pixels[i + 3] = 255;
    }
  }
}

/// Widget that displays the WebSpace logo tinted to the current accent color.
/// Processes icon pixels directly:
/// - Background (white in light / black in dark) → transparent
/// - Structural (black in light / white in dark) → kept as-is
/// - Colored (blue) → replaced with accent color
/// Results are cached per (accentColor, brightness) pair.
class AccentLogo extends StatefulWidget {
  final AccentColor accentColor;
  final double size;
  final Brightness brightness;

  const AccentLogo({
    super.key,
    required this.accentColor,
    required this.size,
    this.brightness = Brightness.light,
  });

  @override
  State<AccentLogo> createState() => _AccentLogoState();
}

class _AccentLogoState extends State<AccentLogo> {
  ui.Image? _image;
  static final Map<String, ui.Image> _cache = {};

  @override
  void initState() {
    super.initState();
    _loadAndProcess();
  }

  @override
  void didUpdateWidget(AccentLogo old) {
    super.didUpdateWidget(old);
    if (old.accentColor != widget.accentColor || old.brightness != widget.brightness) {
      _loadAndProcess();
    }
  }

  String get _cacheKey => '${widget.accentColor.name}_${widget.brightness.name}';

  Future<void> _loadAndProcess() async {
    final key = _cacheKey;
    // Capture widget properties before any awaits to avoid race conditions:
    // if the widget updates mid-flight, stale reads would corrupt the cache.
    final accentColor = widget.accentColor;
    final brightness = widget.brightness;

    if (_cache.containsKey(key)) {
      setState(() => _image = _cache[key]);
      return;
    }

    // Clear stale image while processing so we don't flash the old color
    if (_image != null) {
      setState(() => _image = null);
    }

    final asset = brightness == Brightness.dark
        ? 'assets/webspace_icon_dark.png'
        : 'assets/webspace_icon.png';
    final data = await rootBundle.load(asset);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    final src = frame.image;
    final byteData = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) return;

    final pixels = Uint8List.fromList(byteData.buffer.asUint8List());
    final isLight = brightness == Brightness.light;
    recolorLogoPixels(pixels, accentColor: accentColor, isLight: isLight);

    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels, src.width, src.height, ui.PixelFormat.rgba8888,
      (result) => completer.complete(result),
    );
    final processed = await completer.future;
    _cache[key] = processed;

    if (mounted && _cacheKey == key) {
      setState(() => _image = processed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_image == null) {
      return SizedBox(width: widget.size, height: widget.size);
    }
    return RawImage(
      image: _image,
      width: widget.size,
      height: widget.size,
      filterQuality: FilterQuality.medium,
    );
  }
}
