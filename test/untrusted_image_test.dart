import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/untrusted_image.dart';

import 'helpers/broken_images.dart';

void main() {
  test('a deflated TIFF strip that does not inflate is refused', () {
    expect(decodeUntrustedImage(tiffThatDoesNotInflate()), isNull);
    expect(decodeUntrustedImage(tiffThatDoesNotInflate(compression: 32946)),
        isNull);
  });

  test('a truncated PNG is refused', () {
    expect(decodeUntrustedImage(truncatedPng), isNull);
  });

  test('bytes that are no image are refused', () {
    expect(decodeUntrustedImage(Uint8List.fromList([1, 2, 3, 4])), isNull);
  });

  test('an image decodes', () {
    final png = img.encodePng(img.Image(width: 3, height: 2));
    final decoded = decodeUntrustedImage(png);
    expect(decoded?.width, 3);
    expect(decoded?.height, 2);
  });
}
