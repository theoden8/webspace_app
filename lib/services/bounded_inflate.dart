import 'dart:convert';
import 'dart:typed_data';

/// [compressed] decoded by [codec] in chunks, or null once the output passes
/// [limit]: the output is tallied as it is made, so a decompression bomb
/// stops where it crosses the limit and never materializes. What the codec
/// throws on bad data (zlib's [FormatException]) reaches the caller.
Uint8List? inflateBounded(
  Converter<List<int>, List<int>> codec, {
  required List<int> compressed,
  required int limit,
}) {
  final out = BytesBuilder(copy: false);
  var total = 0;
  var overflow = false;
  final conversion = codec.startChunkedConversion(
    _ChunkSink((chunk) {
      total += chunk.length;
      if (total > limit) {
        overflow = true;
      } else {
        out.add(chunk);
      }
    }),
  );
  const step = 16 * 1024;
  for (var i = 0; i < compressed.length && !overflow; i += step) {
    final end = i + step < compressed.length ? i + step : compressed.length;
    conversion.add(compressed.sublist(i, end));
  }
  if (overflow) return null;
  conversion.close();
  return overflow ? null : out.takeBytes();
}

/// The first [limit] bytes [compressed] decodes to by [codec], where
/// [compressed] may be only the start of a stream, as a ranged download is:
/// unlike [inflateBounded] the stream is never closed, so a cut input is
/// not an error, and decoding stops once [limit] bytes are out. What the
/// codec throws on bad data reaches the caller.
Uint8List inflatePrefix(
  Converter<List<int>, List<int>> codec, {
  required List<int> compressed,
  required int limit,
}) {
  final out = BytesBuilder(copy: false);
  final conversion = codec.startChunkedConversion(
    _ChunkSink((chunk) {
      final room = limit - out.length;
      if (room > 0) out.add(chunk.length > room ? chunk.sublist(0, room) : chunk);
    }),
  );
  const step = 16 * 1024;
  for (var i = 0; i < compressed.length && out.length < limit; i += step) {
    final end = i + step < compressed.length ? i + step : compressed.length;
    conversion.add(compressed.sublist(i, end));
  }
  return out.takeBytes();
}

final class _ChunkSink extends ByteConversionSink {
  _ChunkSink(this.onChunk);

  final void Function(List<int>) onChunk;

  @override
  void add(List<int> chunk) => onChunk(chunk);

  @override
  void addSlice(List<int> chunk, int start, int end, bool isLast) =>
      onChunk(chunk.sublist(start, end));

  @override
  void close() {}
}
