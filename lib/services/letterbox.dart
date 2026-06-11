import 'dart:math' as math;

/// Target size (logical pixels) for the letterboxed web-content box. When
/// [width]/[height] equal the available area, no margin is drawn.
class LetterboxTarget {
  final double width;
  final double height;
  const LetterboxTarget(this.width, this.height);

  @override
  bool operator ==(Object other) =>
      other is LetterboxTarget &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'LetterboxTarget($width, $height)';
}

/// Tor-style letterbox sizing. Snaps the available area DOWN to a
/// [gridWidth] x [gridHeight] grid so many real device sizes collapse onto
/// the same bucket (lower fingerprint entropy); the leftover becomes a margin.
///
/// When [fixedWidth] and [fixedHeight] are both set and positive the box is
/// that exact size, capped to the available area so it never overflows the
/// screen; no grid snap is applied.
///
/// If the available area is smaller than one grid cell on an axis, that axis is
/// returned as-is (no letterbox there) so small screens aren't shrunk away.
LetterboxTarget computeLetterboxTarget({
  required double availableWidth,
  required double availableHeight,
  int? fixedWidth,
  int? fixedHeight,
  double gridWidth = 200,
  double gridHeight = 100,
}) {
  final aw = availableWidth.isFinite ? math.max(0.0, availableWidth) : 0.0;
  final ah = availableHeight.isFinite ? math.max(0.0, availableHeight) : 0.0;
  if (aw <= 0 || ah <= 0) return LetterboxTarget(aw, ah);

  if (fixedWidth != null &&
      fixedWidth > 0 &&
      fixedHeight != null &&
      fixedHeight > 0) {
    return LetterboxTarget(
      math.min(fixedWidth.toDouble(), aw),
      math.min(fixedHeight.toDouble(), ah),
    );
  }

  final w = aw >= gridWidth ? (aw / gridWidth).floor() * gridWidth : aw;
  final h = ah >= gridHeight ? (ah / gridHeight).floor() * gridHeight : ah;
  return LetterboxTarget(w, h);
}
