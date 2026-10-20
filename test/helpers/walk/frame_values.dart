/// An ordered, immutable snapshot of one frame variable's values. Nested
/// collections use another [FrameValues], so equality compares their contents
/// without formatting and joining strings on every asynchronous segment.
final class FrameValues {
  FrameValues(Iterable<Object?> values)
    : _values = List<Object?>.of(values, growable: false);

  final List<Object?> _values;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! FrameValues || _values.length != other._values.length) {
      return false;
    }
    for (var i = 0; i < _values.length; i++) {
      if (_values[i] != other._values[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_values);
}
