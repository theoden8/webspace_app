import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Longest side of a stored custom icon. Matches the size home-shortcut
/// export rasterizes at; in-app renderings are 16-36px.
const int kCustomIconMaxDimension = 256;

/// Normalize a user-picked image into the bytes stored on
/// `WebViewModel.customIconPng`: decode any raster format the `image`
/// package understands (PNG/JPEG/WebP/GIF/BMP/ICO/TIFF), downscale so the
/// longest side is at most [maxDimension] (never upscale), and re-encode
/// as PNG. Returns null when the bytes are not a decodable image.
Uint8List? processCustomIconImage(
  Uint8List raw, {
  int maxDimension = kCustomIconMaxDimension,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  final longest =
      decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longest > maxDimension) {
    final scale = maxDimension / longest;
    decoded = img.copyResize(
      decoded,
      width: (decoded.width * scale).round().clamp(1, maxDimension),
      height: (decoded.height * scale).round().clamp(1, maxDimension),
      interpolation: img.Interpolation.average,
    );
  }
  return Uint8List.fromList(img.encodePng(decoded));
}

/// [processCustomIconImage] off the UI thread — decoding a camera-sized
/// JPEG takes long enough to drop frames.
Future<Uint8List?> processCustomIconImageAsync(Uint8List raw) {
  return compute(processCustomIconImage, raw);
}
