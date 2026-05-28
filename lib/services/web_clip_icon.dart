import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Pure helper: normalize an arbitrary raster favicon into a square PNG fit
/// for an iOS Web Clip `Icon` payload. iOS renders the Home Screen tile from
/// this PNG (it applies its own corner mask), so we only need a square,
/// reasonably sized, opaque-friendly PNG. Returns null when the bytes can't
/// be decoded (e.g. an SVG or a corrupt download) so the caller can fall back
/// to the bundled app icon.
class WebClipIcon {
  static Uint8List? encodeSquarePng(Uint8List raw, {int size = 180}) {
    try {
      // decodeImage probes multiple format decoders; a malformed download can
      // make one of them overrun its buffer and throw rather than return null.
      final decoded = img.decodeImage(raw);
      if (decoded == null) return null;
      final resized = img.copyResize(
        decoded,
        width: size,
        height: size,
        interpolation: img.Interpolation.cubic,
      );
      return img.encodePng(resized);
    } catch (_) {
      return null;
    }
  }
}
