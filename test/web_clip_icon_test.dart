import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/web_clip_icon.dart';

void main() {
  test('encodeSquarePng squares + re-encodes a raster favicon', () {
    final src = img.Image(width: 32, height: 64);
    img.fill(src, color: img.ColorRgb8(10, 20, 30));
    final raw = Uint8List.fromList(img.encodePng(src));

    final out = WebClipIcon.encodeSquarePng(raw, size: 120);
    expect(out, isNotNull);
    final decoded = img.decodeImage(out!);
    expect(decoded, isNotNull);
    expect(decoded!.width, 120);
    expect(decoded.height, 120);
  });

  test('encodeSquarePng returns null on undecodable bytes', () {
    expect(
      WebClipIcon.encodeSquarePng(Uint8List.fromList([1, 2, 3, 4])),
      isNull,
    );
  });
}
