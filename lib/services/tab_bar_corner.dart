import 'dart:ui' show Offset, Size;

/// Screen corner the floating tab-bar button rests in. Persisted per site
/// by enum name; the button is placed by dragging it, not by a settings
/// control.
enum TabBarCorner { topLeft, topRight, bottomLeft, bottomRight }

TabBarCorner? tabBarCornerFromName(String? name) {
  for (final corner in TabBarCorner.values) {
    if (corner.name == name) return corner;
  }
  return null;
}

bool tabBarCornerIsRight(TabBarCorner corner) =>
    corner == TabBarCorner.topRight || corner == TabBarCorner.bottomRight;

bool tabBarCornerIsTop(TabBarCorner corner) =>
    corner == TabBarCorner.topLeft || corner == TabBarCorner.topRight;

/// Nearest corner for a button whose center sits at the given fractional
/// position (Alignment convention: -1..1 per axis, negative = left/top).
TabBarCorner tabBarCornerNearest(double x, double y) {
  if (y < 0) {
    return x > 0 ? TabBarCorner.topRight : TabBarCorner.topLeft;
  }
  return x > 0 ? TabBarCorner.bottomRight : TabBarCorner.bottomLeft;
}

/// Fractional position (Alignment convention, clamped to -1..1) of a
/// button centered under [localPointer] inside [area], where the button
/// travels within an [margin]-inset box and is [buttonSize] wide/tall.
Offset tabBarCornerDragFraction(
  Offset localPointer,
  Size area, {
  required double buttonSize,
  required double margin,
}) {
  double axis(double position, double extent) {
    final span = extent - 2 * margin - buttonSize;
    if (span <= 0) return 0;
    final fraction = 2 * (position - margin - buttonSize / 2) / span - 1;
    return fraction.clamp(-1.0, 1.0);
  }

  return Offset(axis(localPointer.dx, area.width), axis(localPointer.dy, area.height));
}
