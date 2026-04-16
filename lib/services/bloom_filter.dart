import 'dart:math' as math;
import 'dart:typed_data';

/// Simple Bloom filter for fast probabilistic set membership checks.
/// False positives possible (configurable rate), false negatives impossible.
///
/// Uses FNV-1a hash with multiple seeds via the Kirsch-Mitzenmacher technique.
/// JS-compatible: see [toMap] for the binary format that mirrors the JS reader.
class BloomFilter {
  final Uint8List bits;
  final int bitCount;
  final int k;

  BloomFilter._(this.bits, this.bitCount, this.k);

  /// Build a Bloom filter sized for items with target false positive [fpRate].
  /// Default 0.001 (0.1%) gives ~1MB for 588K items, ~10 hash functions.
  factory BloomFilter.build(Iterable<String> items, {double fpRate = 0.001}) {
    final n = items.length;
    if (n == 0) {
      return BloomFilter._(Uint8List(8), 64, 1);
    }
    // Optimal: m = -n * ln(p) / (ln 2)^2, k = (m/n) * ln 2
    final ln2 = math.ln2;
    final m = (-n * math.log(fpRate) / (ln2 * ln2)).ceil();
    final byteCount = (m / 8).ceil();
    final bitCount = byteCount * 8;
    final k = ((m / n) * ln2).round().clamp(1, 16);
    final bits = Uint8List(byteCount);

    for (final item in items) {
      _setBits(bits, bitCount, k, item);
    }
    return BloomFilter._(bits, bitCount, k);
  }

  static int _hash(String s, int seed) {
    int h = seed & 0xFFFFFFFF;
    for (int i = 0; i < s.length; i++) {
      h ^= s.codeUnitAt(i);
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return h;
  }

  static void _setBits(Uint8List bits, int bitCount, int k, String item) {
    final h1 = _hash(item, 0x811C9DC5);
    final h2 = _hash(item, 0xCBF29CE4);
    for (int i = 0; i < k; i++) {
      final h = (h1 + i * h2) & 0xFFFFFFFF;
      final pos = h % bitCount;
      bits[pos >> 3] |= 1 << (pos & 7);
    }
  }

  bool contains(String item) {
    final h1 = _hash(item, 0x811C9DC5);
    final h2 = _hash(item, 0xCBF29CE4);
    for (int i = 0; i < k; i++) {
      final h = (h1 + i * h2) & 0xFFFFFFFF;
      final pos = h % bitCount;
      if ((bits[pos >> 3] & (1 << (pos & 7))) == 0) return false;
    }
    return true;
  }

  /// Serialize to a Map suitable for JS consumption.
  /// JS reads `bits` (List<int> bytes), `bitCount` (int), `k` (int).
  Map<String, dynamic> toMap() => {
        'bits': bits,
        'bitCount': bitCount,
        'k': k,
      };

  int get sizeInBytes => bits.length;
}
