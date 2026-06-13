import 'dart:math' as math;

/// Upper bound on the letterbox margin per axis, as a fraction of the
/// available extent. A coarse fixed grid (200x100) trims almost half of a
/// phone-width viewport (e.g. 390 -> 200), so the margin is capped here and
/// the grid is refined until the trimmed strip fits the budget. Tuned so a
/// maximised desktop window still snaps to the 200x100 grid (1366 -> 1200 is
/// 12.15%).
const double kLetterboxMaxMarginFraction = 1 / 8;

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

/// Snap [available] DOWN to the coarsest grid (starting at [grid], halving)
/// whose trimmed margin stays within [kLetterboxMaxMarginFraction]. Coarse
/// steps bucket many real sizes onto one value (lower fingerprint entropy);
/// refining only when the coarse step would eat too much keeps the margin a
/// thin strip on small screens instead of half the viewport.
double _snapAxis(double available, double grid) {
  if (available <= 0 || !available.isFinite) return math.max(0.0, available);
  for (var step = grid; step >= 1; step /= 2) {
    if (available < step) continue;
    final snapped = (available / step).floorToDouble() * step;
    if (available - snapped <= kLetterboxMaxMarginFraction * available) {
      return snapped;
    }
  }
  return available;
}

/// Tor-style letterbox sizing. Snaps the available area DOWN to a grid so many
/// real device sizes collapse onto the same bucket (lower fingerprint
/// entropy); the leftover becomes a margin. The grid starts at
/// [gridWidth] x [gridHeight] and is refined per axis until the margin fits
/// [kLetterboxMaxMarginFraction], so the box is never shrunk to a sliver on a
/// phone-sized viewport (where a flat 200x100 grid would trim ~half).
///
/// When [fixedWidth] and [fixedHeight] are both set and positive the box is
/// that exact size, capped to the available area so it never overflows the
/// screen; no grid snap is applied.
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

  return LetterboxTarget(_snapAxis(aw, gridWidth), _snapAxis(ah, gridHeight));
}
