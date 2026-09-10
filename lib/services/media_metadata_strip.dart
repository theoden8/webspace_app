import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Strips what a user-picked file says about the user before it is inlined
/// onto a site model as a `data:` URL. The virtual camera, microphone and
/// screen shims hand those bytes to page script, so EXIF GPS, device model
/// and capture time have to go at pick time.
///
/// Images are re-encoded without EXIF, XMP or ICC. ISO-BMFF containers
/// (mp4, m4v, mov, m4a) get every `udta`, `meta` and `uuid` box overwritten
/// in place with `free`, sizes untouched, so chunk offsets stay valid. MP3
/// loses its ID3v2 and ID3v1 tags. Other containers (webm, ogg, wav, flac,
/// aac) are delivered as picked.

/// [raw] re-encoded without metadata. JPEG stays JPEG (a photo re-encoded
/// as PNG would be several times larger on the model); everything else
/// becomes PNG. Null when the bytes do not decode as an image.
({Uint8List bytes, String mime})? stripImageMetadata(
  Uint8List raw, {
  required bool jpeg,
}) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(raw);
  } catch (_) {
    return null;
  }
  if (decoded == null) return null;
  decoded.exif = img.ExifData();
  decoded.iccProfile = null;
  if (jpeg) {
    return (
      bytes: Uint8List.fromList(img.encodeJpg(decoded, quality: 92)),
      mime: 'image/jpeg',
    );
  }
  return (bytes: Uint8List.fromList(img.encodePng(decoded)), mime: 'image/png');
}

/// [stripImageMetadata] shaped for `compute`: `(bytes, jpeg)`.
({Uint8List bytes, String mime})? stripImageMetadataForIsolate(
  (Uint8List, bool) args,
) =>
    stripImageMetadata(args.$1, jpeg: args.$2);

/// [raw] with the container metadata for [extension] removed. Bytes come
/// back as they are for a container this does not parse.
Uint8List stripContainerMetadata(Uint8List raw, String extension) {
  switch (extension) {
    case 'mp4':
    case 'm4v':
    case 'mov':
    case 'm4a':
      return stripIsoBmffMetadata(raw);
    case 'mp3':
      return stripId3Tags(raw);
    default:
      return raw;
  }
}

const _isoContainers = {'moov', 'trak', 'mdia', 'minf', 'stbl', 'moof', 'traf'};
const _isoMetadataBoxes = {'udta', 'meta', 'uuid'};

/// A copy of [raw] with every `udta`, `meta` and `uuid` box, at the top
/// level or inside a track container, turned into a zero-filled `free` box
/// of the same size.
Uint8List stripIsoBmffMetadata(Uint8List raw) {
  final out = Uint8List.fromList(raw);
  _blankBoxes(out, 0, out.length);
  return out;
}

void _blankBoxes(Uint8List b, int start, int end) {
  var pos = start;
  while (pos + 8 <= end) {
    final data = ByteData.sublistView(b, pos, end);
    var size = data.getUint32(0);
    final type = String.fromCharCodes(b, pos + 4, pos + 8);
    var header = 8;
    if (size == 1) {
      if (pos + 16 > end || data.getUint32(8) != 0) return;
      size = data.getUint32(12);
      header = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < header || pos + size > end) return;
    if (_isoMetadataBoxes.contains(type)) {
      b.setRange(pos + 4, pos + 8, 'free'.codeUnits);
      b.fillRange(pos + header, pos + size, 0);
    } else if (_isoContainers.contains(type)) {
      _blankBoxes(b, pos + header, pos + size);
    }
    pos += size;
  }
}

/// [raw] without leading ID3v2 tags or a trailing ID3v1 tag. MPEG audio
/// frames are self-delimiting, so cutting the tags leaves a valid stream.
Uint8List stripId3Tags(Uint8List raw) {
  var start = 0;
  var end = raw.length;
  while (end - start >= 10 &&
      raw[start] == 0x49 &&
      raw[start + 1] == 0x44 &&
      raw[start + 2] == 0x33) {
    final size = ((raw[start + 6] & 0x7f) << 21) |
        ((raw[start + 7] & 0x7f) << 14) |
        ((raw[start + 8] & 0x7f) << 7) |
        (raw[start + 9] & 0x7f);
    final footer = (raw[start + 5] & 0x10) != 0 ? 10 : 0;
    final total = 10 + size + footer;
    if (start + total > end) break;
    start += total;
  }
  if (end - start >= 128 &&
      raw[end - 128] == 0x54 &&
      raw[end - 127] == 0x41 &&
      raw[end - 126] == 0x47) {
    end -= 128;
  }
  if (start == 0 && end == raw.length) return raw;
  return raw.sublist(start, end);
}
