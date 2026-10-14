import 'dart:typed_data';

/// A 4x4 grayscale TIFF whose one strip claims [compression] (8 deflate,
/// 32946 zip) but holds bytes that do not inflate: the image package hands
/// them to its ZLibDecoder, which throws `FormatException: Filter error, bad
/// data`.
Uint8List tiffThatDoesNotInflate({int compression = 8}) {
  const strip = <int>[
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, //
    0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
  ];
  final b = BytesBuilder();
  void u16(int v) => b.add([v & 0xff, (v >> 8) & 0xff]);
  void u32(int v) =>
      b.add([v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);
  // (tag, type: 3 short or 4 long, value); 273 is the strip offset.
  final entries = <(int, int, int)>[
    (256, 3, 4),
    (257, 3, 4),
    (258, 3, 8),
    (259, 3, compression),
    (262, 3, 1),
    (273, 4, 0),
    (277, 3, 1),
    (278, 3, 4),
    (279, 4, strip.length),
  ];
  final stripOffset = 8 + 2 + entries.length * 12 + 4;
  b.add([0x49, 0x49]);
  u16(42);
  u32(8);
  u16(entries.length);
  for (final (tag, type, value) in entries) {
    u16(tag);
    u16(type);
    u32(1);
    final v = tag == 273 ? stripOffset : value;
    if (type == 3) {
      u16(v);
      u16(0);
    } else {
      u32(v);
    }
  }
  u32(0);
  b.add(strip);
  return b.toBytes();
}

/// The first 16 bytes of a PNG: signature and the start of an IHDR the
/// decoders read past the end of (a [RangeError]).
final Uint8List truncatedPng = Uint8List.fromList(
    [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]);
