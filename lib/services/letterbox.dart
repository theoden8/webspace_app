import 'dart:math' as math;

/// Upper bound on the letterbox margin per axis, as a fraction of the
/// available extent. Reached on large (desktop) viewports, where the coarse
/// 200x100 grid's ~12% trim is accepted to keep size buckets few. A coarse
/// fixed grid trims almost half of a phone-width viewport (e.g. 390 -> 200),
/// so the margin is capped and the grid is refined until the trimmed strip
/// fits the budget. Tuned so a maximised desktop window still snaps to the
/// 200x100 grid (1366 -> 1200 is 12.15%).
const double kLetterboxMaxMarginFraction = 1 / 8;

/// Smallest margin budget, applied on narrow/short (phone) viewports so the
/// bars stay thin instead of eating the desktop-sized 12.5%.
const double kLetterboxMinMarginFraction = 1 / 16;

/// Smallest extent that is treated as a full desktop window and gets the loose
/// [kLetterboxMaxMarginFraction] budget (so 1366 still snaps to the 200 grid).
const double _kLetterboxDesktopExtent = 1366.0;

/// Largest extent that is treated as a phone/small viewport and gets the tight
/// [kLetterboxMinMarginFraction] budget. Between this and
/// [_kLetterboxDesktopExtent] the budget ramps linearly.
const double _kLetterboxSmallExtent = 960.0;

/// Margin budget for an axis of length [extent]. Flat at the tight phone budget
/// up to [_kLetterboxSmallExtent], then ramps to the loose desktop budget by
/// [_kLetterboxDesktopExtent]. Phones thus refine to a finer grid and keep thin
/// bars (e.g. 390 -> 375, 873 -> 850) at the cost of a few more buckets, while a
/// maximised desktop window still snaps to the coarse 200-wide grid (1366 ->
/// 1200) for low fingerprint entropy.
double _maxMarginFraction(double extent) {
  final t = ((extent - _kLetterboxSmallExtent) /
          (_kLetterboxDesktopExtent - _kLetterboxSmallExtent))
      .clamp(0.0, 1.0);
  return kLetterboxMinMarginFraction +
      t * (kLetterboxMaxMarginFraction - kLetterboxMinMarginFraction);
}

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
/// whose trimmed margin stays within [_maxMarginFraction] for this extent.
/// Coarse steps bucket many real sizes onto one value (lower fingerprint
/// entropy); refining only when the coarse step would eat too much keeps the
/// margin a thin strip on small screens instead of half the viewport. The
/// budget shrinks with the extent, so phones refine further than desktops and
/// end up with thinner bars.
double _snapAxis(double available, double grid) {
  if (available <= 0 || !available.isFinite) return math.max(0.0, available);
  final budget = _maxMarginFraction(available) * available;
  for (var step = grid; step >= 1; step /= 2) {
    if (available < step) continue;
    final snapped = (available / step).floorToDouble() * step;
    if (available - snapped <= budget) {
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
