/// SplitMix64, the walks' only source of randomness. Written here rather than
/// taken from `dart:math`, whose `Random(seed)` stream no SDK release promises
/// to keep, so a seed names the same actions on every runner and after every
/// upgrade. Relies on the Dart VM's wrapping 64-bit `int`; tests never run on
/// the web.
final class WalkRng {
  WalkRng(this._state);

  int _state;

  int nextUint64() {
    _state += 0x9E3779B97F4A7C15;
    var z = _state;
    z = (z ^ (z >>> 30)) * 0xBF58476D1CE4E5B9;
    z = (z ^ (z >>> 27)) * 0x94D049BB133111EB;
    return z ^ (z >>> 31);
  }

  /// Uniform in `0 <= n < max` up to a bias below 2^-40 for any `max` a walk
  /// uses.
  int nextInt(int max) {
    assert(max > 0, 'nextInt needs a positive bound');
    return (nextUint64() >>> 11) % max;
  }

  /// One of [weighted]'s keys, each drawn in proportion to its weight.
  T pick<T>(Map<T, int> weighted) {
    final total = weighted.values.fold(0, (a, w) => a + w);
    var at = nextInt(total);
    for (final MapEntry(:key, :value) in weighted.entries) {
      if (at < value) return key;
      at -= value;
    }
    throw StateError('unreachable: $at past a total of $total');
  }
}
