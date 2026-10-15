import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../tool/macos_app_icon.dart';

/// macOS draws its icon as the PNG has it, so the shape has to be in the
/// committed set. A square there (flutter_launcher_icons' output) shows with
/// sharp corners, or on a grey tile on macOS 26. Rung 5: the build rewrites
/// the set only when the artwork changes, so a square another tool writes over
/// it ships unless its pixels are checked.
void main() {
  img.Image icon(int size) => img.decodePng(
    File('$macosIconSet/app_icon_$size.png').readAsBytesSync(),
  )!;

  for (final size in macosIconSizes) {
    test('the $size px icon has a transparent margin and an opaque body', () {
      final i = icon(size);
      expect((i.width, i.height), (size, size));
      expect(i.getPixel(0, 0).a, lessThan(16));
      expect(i.getPixel(size ~/ 2, size ~/ 2).a, 255);
    });
  }

  test('the body has rounded corners', () {
    final i = icon(1024);
    expect(i.getPixel(110, 110).a, lessThan(16));
    expect(i.getPixel(512, 110).a, 255);
    expect(i.getPixel(110, 512).a, 255);
  });
}
