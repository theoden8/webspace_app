import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:webspace/services/media_metadata_strip.dart';

List<int> box(List<int> type, List<int> payload) {
  final size = 8 + payload.length;
  return [
    (size >> 24) & 0xff,
    (size >> 16) & 0xff,
    (size >> 8) & 0xff,
    size & 0xff,
    ...type,
    ...payload,
  ];
}

List<int> t(String type) => type.codeUnits;

void main() {
  group('ISO-BMFF (SEC-016)', () {
    final gps = '+37.7749-122.4194/'.codeUnits;
    final udta = box(t('udta'), box([0xa9, 0x78, 0x79, 0x7a], gps));
    final trakUdta =
        box(t('trak'), box(t('udta'), box(t('meta'), 'trak-meta'.codeUnits)));
    final moov = box(t('moov'), [
      ...box(t('mvhd'), List.filled(20, 1)),
      ...udta,
      ...trakUdta,
    ]);
    final xmp = box(t('uuid'), [
      ...List.filled(16, 0xab),
      ...'<x:xmpmeta>GPS</x:xmpmeta>'.codeUnits,
    ]);
    final mdat = box(t('mdat'), [1, 2, 3, 4, 5]);
    final file = Uint8List.fromList([
      ...box(t('ftyp'), 'isom'.codeUnits),
      ...moov,
      ...xmp,
      ...mdat,
    ]);

    test('udta, meta and uuid boxes are blanked in place', () {
      final out = stripIsoBmffMetadata(file);
      final text = String.fromCharCodes(out);
      expect(out.length, file.length);
      expect(text, isNot(contains('+37.7749')));
      expect(text, isNot(contains('xmpmeta')));
      expect(text, isNot(contains('trak-meta')));
      expect(text, isNot(contains('udta')));
      expect(text, isNot(contains('uuid')));
      expect(text, contains('ftyp'));
      expect(text, contains('mvhd'));
      expect('free'.allMatches(text).length, 3);
    });

    test('media data keeps its offset and bytes', () {
      final out = stripIsoBmffMetadata(file);
      final at = file.length - mdat.length;
      expect(out.sublist(at), mdat);
    });

    test('the input is not modified', () {
      stripIsoBmffMetadata(file);
      expect(String.fromCharCodes(file), contains('+37.7749'));
    });

    test('a truncated or oversized box stops the walk without throwing', () {
      final bad = Uint8List.fromList([0, 0, 0, 40, ...t('moov'), 1, 2, 3]);
      expect(stripIsoBmffMetadata(bad), bad);
      final zero = Uint8List.fromList([0, 0, 0, 0, ...t('udta'), 9, 9]);
      final out = stripIsoBmffMetadata(zero);
      expect(String.fromCharCodes(out, 4, 8), 'free');
      expect(out.sublist(8), [0, 0]);
    });
  });

  group('MP3 (SEC-016)', () {
    final frame = [0xff, 0xfb, 0x90, 0x00, ...List.filled(20, 7)];

    test('ID3v2 header and ID3v1 trailer are cut', () {
      final tag = 'TXXX....LAT=37.77'.codeUnits;
      final id3 = [0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 0, tag.length, ...tag];
      final v1 = [...'TAG'.codeUnits, ...List.filled(125, 0x20)];
      final out = stripId3Tags(Uint8List.fromList([...id3, ...frame, ...v1]));
      expect(out, Uint8List.fromList(frame));
    });

    test('a bare stream comes back as it is', () {
      final raw = Uint8List.fromList(frame);
      expect(stripId3Tags(raw), same(raw));
    });

    test('a tag claiming more than the file holds is left alone', () {
      final raw = Uint8List.fromList([0x49, 0x44, 0x33, 3, 0, 0, 0, 0, 7, 0, 1]);
      expect(stripId3Tags(raw), same(raw));
    });
  });

  group('images (SEC-016)', () {
    test('a JPEG loses its EXIF and stays a JPEG', () {
      final image = img.Image(width: 4, height: 4);
      image.exif.imageIfd['Make'] = 'Phone Co';
      final raw = Uint8List.fromList(img.encodeJpg(image));
      expect(String.fromCharCodes(raw), contains('Phone Co'));
      final out = stripImageMetadata(raw, jpeg: true)!;
      expect(out.mime, 'image/jpeg');
      expect(String.fromCharCodes(out.bytes), isNot(contains('Phone Co')));
      expect(img.decodeImage(out.bytes)!.exif.isEmpty, isTrue);
    });

    test('other formats become PNG with the same pixels', () {
      final image = img.Image(width: 2, height: 2);
      image.setPixelRgb(1, 1, 200, 10, 30);
      final raw = Uint8List.fromList(img.encodeBmp(image));
      final out = stripImageMetadata(raw, jpeg: false)!;
      expect(out.mime, 'image/png');
      final back = img.decodeImage(out.bytes)!;
      expect(back.getPixel(1, 1).r, 200);
      expect(back.getPixel(0, 0).r, 0);
    });

    test('bytes that are not an image are refused', () {
      expect(stripImageMetadata(Uint8List.fromList([1, 2, 3]), jpeg: false),
          isNull);
    });
  });

  test('a container this does not parse passes through untouched', () {
    final webm = Uint8List.fromList([0x1a, 0x45, 0xdf, 0xa3, 1, 2, 3]);
    expect(stripContainerMetadata(webm, 'webm'), same(webm));
    expect(stripContainerMetadata(webm, 'wav'), same(webm));
  });

  test('extensions route to their container walker', () {
    final udta = Uint8List.fromList(box(t('udta'), [1, 2]));
    for (final ext in ['mp4', 'm4v', 'mov', 'm4a']) {
      expect(String.fromCharCodes(stripContainerMetadata(udta, ext), 4, 8),
          'free');
    }
  });
}
