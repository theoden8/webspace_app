import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart' show Deflate, getCrc32;

/// One entry of an archive [zipOf] writes, with every field an archiver
/// would get right open to a test that needs it wrong.
class ZipEntryBytes {
  ZipEntryBytes(
    this.name, {
    String text = '',
    Uint8List? content,
    this.deflate = true,
    this.flags = 0,
    this.madeBy = 0x0314,
    this.externalAttributes = 0x81a40000,
    this.crc,
    this.declaredSize,
    this.method,
    this.nameBytes,
  }) : content = content ?? Uint8List.fromList(utf8.encode(text));

  final String name;
  final Uint8List content;
  final bool deflate;
  final int flags;

  /// Unix (3) in the high byte, as Info-ZIP writes it.
  final int madeBy;

  /// A regular file, mode 0644, in the high word.
  final int externalAttributes;
  final int? crc;
  final int? declaredSize;
  final int? method;
  final Uint8List? nameBytes;
}

/// A ZIP archive of [entries], written byte by byte.
Uint8List zipOf(List<ZipEntryBytes> entries) {
  final out = BytesBuilder();
  final directory = BytesBuilder();
  for (final e in entries) {
    final name = e.nameBytes ?? Uint8List.fromList(utf8.encode(e.name));
    final data = e.deflate ? Deflate(e.content).getBytes() : e.content;
    final method = e.method ?? (e.deflate ? 8 : 0);
    final crc = e.crc ?? getCrc32(e.content);
    final size = e.declaredSize ?? e.content.length;
    final offset = out.length;
    out
      ..add(_u32(0x04034b50))
      ..add(_u16(20))
      ..add(_u16(e.flags))
      ..add(_u16(method))
      ..add(_u32(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(size))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(name)
      ..add(data);
    directory
      ..add(_u32(0x02014b50))
      ..add(_u16(e.madeBy))
      ..add(_u16(20))
      ..add(_u16(e.flags))
      ..add(_u16(method))
      ..add(_u32(0))
      ..add(_u32(crc))
      ..add(_u32(data.length))
      ..add(_u32(size))
      ..add(_u16(name.length))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u16(0))
      ..add(_u32(e.externalAttributes))
      ..add(_u32(offset))
      ..add(name);
  }
  final directoryOffset = out.length;
  final directoryBytes = directory.toBytes();
  out
    ..add(directoryBytes)
    ..add(_u32(0x06054b50))
    ..add(_u16(0))
    ..add(_u16(0))
    ..add(_u16(entries.length))
    ..add(_u16(entries.length))
    ..add(_u32(directoryBytes.length))
    ..add(_u32(directoryOffset))
    ..add(_u16(0));
  return out.toBytes();
}

/// A Chrome package, version 3, around [zip]: the header's contents are
/// opaque to the reader, so any bytes stand in for the signed protobuf.
Uint8List crx3Of(Uint8List zip, {int headerLength = 64}) => Uint8List.fromList([
  ...ascii.encode('Cr24'),
  ..._u32(3),
  ..._u32(headerLength),
  ...List.filled(headerLength, 0x5a),
  ...zip,
]);

/// A Chrome package, version 2, around [zip].
Uint8List crx2Of(
  Uint8List zip, {
  int keyLength = 162,
  int signatureLength = 128,
}) => Uint8List.fromList([
  ...ascii.encode('Cr24'),
  ..._u32(2),
  ..._u32(keyLength),
  ..._u32(signatureLength),
  ...List.filled(keyLength + signatureLength, 0x5a),
  ...zip,
]);

/// The smallest manifest a package is read with, plus [extra] keys.
String manifestJson({Map<String, Object?> extra = const {}}) => jsonEncode({
  'manifest_version': 3,
  'name': 'Sample',
  'version': '1.0',
  ...extra,
});

/// An archive holding a manifest and a content script.
Uint8List sampleZip({Map<String, Object?> manifest = const {}}) => zipOf([
  ZipEntryBytes('manifest.json', text: manifestJson(extra: manifest)),
  ZipEntryBytes('content.js', text: 'document.title += "!";'),
]);

Uint8List _u16(int v) =>
    (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();

Uint8List _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
