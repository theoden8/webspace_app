import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// [bytes], from a page or a file the user picked, decoded, or null when the
/// decoder rejects them: an [img.ImageException] for a malformed image, a
/// [RangeError] for a truncated one or bad EXIF, a [FormatException] for a
/// deflated TIFF or EXR body that does not inflate.
img.Image? decodeUntrustedImage(Uint8List bytes) {
  try {
    return img.decodeImage(bytes);
  } on img.ImageException {
    return null;
  } on RangeError {
    return null;
  } on FormatException {
    return null;
  }
}
