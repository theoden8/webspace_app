import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/custom_icon.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/web_view_model.dart';

Uint8List _pngOfSize(int w, int h) {
  final im = img.Image(width: w, height: h);
  img.fill(im, color: img.ColorRgb8(30, 120, 200));
  return Uint8List.fromList(img.encodePng(im));
}

void main() {
  group('processCustomIconImage', () {
    test('downscales oversized images preserving aspect ratio', () {
      final out = processCustomIconImage(_pngOfSize(1024, 512));
      expect(out, isNotNull);
      final decoded = img.decodePng(out!);
      expect(decoded!.width, kCustomIconMaxDimension);
      expect(decoded.height, kCustomIconMaxDimension ~/ 2);
    });

    test('keeps small images at their size and re-encodes as PNG', () {
      final jpg = Uint8List.fromList(
          img.encodeJpg(img.Image(width: 40, height: 40)));
      final out = processCustomIconImage(jpg);
      expect(out, isNotNull);
      final decoded = img.decodePng(out!);
      expect(decoded, isNotNull);
      expect(decoded!.width, 40);
      expect(decoded.height, 40);
    });

    test('returns null for undecodable bytes', () {
      final garbage = Uint8List.fromList(List<int>.filled(64, 7));
      expect(processCustomIconImage(garbage), isNull);
    });
  });

  group('WebViewModel.customIconPng', () {
    test('round-trips through toJson/fromJson', () {
      final icon = _pngOfSize(16, 16);
      final model = WebViewModel(
        initUrl: 'https://example.com',
        customIconPng: icon,
      );
      final restored = WebViewModel.fromJson(model.toJson(), null);
      expect(restored.customIconPng, icon);
    });

    test('omitted from JSON when unset; malformed base64 tolerated', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.toJson().containsKey('customIconPng'), isFalse);

      final json = model.toJson()..['customIconPng'] = 'not-base64!!!';
      expect(WebViewModel.fromJson(json, null).customIconPng, isNull);
    });

    test('never rides the QR share payload (EDIT-008)', () {
      final model = WebViewModel(
        initUrl: 'https://example.com',
        customIconPng: _pngOfSize(16, 16),
      );
      final shared = SiteSettingsQrCodec.shareableSubset(model.toJson());
      expect(shared.containsKey('customIconPng'), isFalse);
    });
  });
}
