import 'package:flutter/widgets.dart';

/// The body inset the Android blank-surface repaint nudge is applying right
/// now (`_nudgeSurfaceRepaint`, BUG-001 / PAUSE-015). Zero in steady state.
///
/// The nudge shrinks the body by a pixel a few times a second so the
/// hybrid-composition platform view recomposites. Anything below it that
/// quantises its own size has to snap against the settled extent and re-apply
/// the pixel itself, or the toggle moves a whole quantum: the letterbox box
/// (ETP-020) drops a full grid step and its bars flash in and out. Descendants
/// read the inset here rather than through [WebViewConfig] because it is host
/// layout state, not per-site configuration; a nested webview pushed on its own
/// route has no scope above it and correctly reads zero.
class SurfaceNudgeScope extends InheritedWidget {
  const SurfaceNudgeScope({
    super.key,
    required this.bottomInset,
    required super.child,
  });

  final double bottomInset;

  static double bottomInsetOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<SurfaceNudgeScope>()
          ?.bottomInset ??
      0.0;

  @override
  bool updateShouldNotify(SurfaceNudgeScope oldWidget) =>
      oldWidget.bottomInset != bottomInset;
}
