import 'package:flutter/widgets.dart';
import 'package:webspace/platform/host_platform.dart';

/// A site's page that hands its clicks to Flutter while another route is over
/// its own: a menu, a dialog, a sheet (NAV-017).
///
/// A macOS platform view has no gesture arena (flutter/flutter#128519): the
/// engine gives Flutter only the clicks that land where Flutter painted over
/// the native view, and the native view takes the rest. A popup menu's
/// barrier paints nothing, so a click on the page beside the menu reaches the
/// page and the menu stays open. While covered, this paints a veil no eye can
/// see over the page, so the click reaches the barrier of the route on top.
class RouteCover extends StatelessWidget {
  @visibleForTesting
  const RouteCover({super.key, required this.page});

  /// [page] covered where its platform view takes clicks Flutter has not
  /// painted over: macOS. Elsewhere the route's barrier already has them.
  static Widget over(Widget page) =>
      hostIsMacOS ? RouteCover(page: page) : page;

  final Widget page;

  /// The least paint the engine counts as Flutter's: a fully transparent
  /// one draws nothing, so it would not cover the native view.
  static const veil = Color(0x01000000);

  @override
  Widget build(BuildContext context) {
    final covered = !(ModalRoute.isCurrentOf(context) ?? true);
    // The page stays the stack's first child either way, so the veil comes
    // and goes without remounting the platform view.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        page,
        if (covered)
          const Positioned.fill(
            child: IgnorePointer(child: ColoredBox(color: veil)),
          ),
      ],
    );
  }
}
