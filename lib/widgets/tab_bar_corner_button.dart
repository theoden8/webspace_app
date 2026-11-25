import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/sidebar_arrow_tab.dart';

/// Floating circular button that reveals the site strip on demand.
///
/// Tap fires [onTap]. Dragging the button — either immediately
/// (press-and-move, the natural mouse gesture on emulators/desktops) or
/// after a long-press hold — reports the pointer's global position through
/// [onDragBegin]/[onDragUpdate] so the owner can carry the button along,
/// then [onDragEnd] lets it snap to a corner. Both recognizers route to the
/// same callbacks; only one wins the arena per gesture.
class TabBarCornerButton extends StatelessWidget {
  const TabBarCornerButton({
    super.key,
    required this.dragging,
    required this.onTap,
    required this.onDragBegin,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool dragging;
  final VoidCallback onTap;
  final ValueChanged<Offset> onDragBegin;
  final ValueChanged<Offset> onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (details) => onDragBegin(details.globalPosition),
      onLongPressMoveUpdate: (details) => onDragUpdate(details.globalPosition),
      onLongPressEnd: (_) => onDragEnd(),
      onLongPressCancel: onDragEnd,
      onPanStart: (details) => onDragBegin(details.globalPosition),
      onPanUpdate: (details) => onDragUpdate(details.globalPosition),
      onPanEnd: (_) => onDragEnd(),
      onPanCancel: onDragEnd,
      child: AnimatedScale(
        scale: dragging ? FloatingButton.dragScale : 1.0,
        duration: Motion.press,
        child: Material(
          color: Theme.of(context).colorScheme.primary.withOpacity(FloatingButton.surfaceOpacity),
          shape: const CircleBorder(),
          elevation: dragging ? Elevations.floatingActive : Elevations.floating,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(FloatingButton.padding),
              child: Icon(
                Icons.tab,
                size: IconSizes.floating,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [TabBarCornerButton] resting in [corner] of the area this fills, carried
/// anywhere in it by a drag and gliding on release to the nearest corner,
/// which [onCornerChosen] reports. Alignment-based, so the resting spot
/// tracks resizes; outside the button it is transparent to hits. Place it
/// where it fills the area the button moves in, such as a `Positioned.fill`.
class TabBarCornerOverlay extends StatefulWidget {
  const TabBarCornerOverlay({
    super.key,
    required this.corner,
    required this.onTap,
    required this.onCornerChosen,
    this.onDock,
  });

  final TabBarCorner corner;
  final VoidCallback onTap;
  final ValueChanged<TabBarCorner> onCornerChosen;

  /// Let go in the dock zone on the left edge: how far down it, from 0 to
  /// 1, for the sidebar's arrow tab to take its place (TAB-038). Null keeps
  /// it a button wherever it is let go.
  final ValueChanged<double>? onDock;

  @override
  State<TabBarCornerOverlay> createState() => _TabBarCornerOverlayState();
}

class _TabBarCornerOverlayState extends State<TabBarCornerOverlay> {
  static const double _margin = Spacing.lg;
  static const double _buttonSize =
      FloatingButton.padding * 2 + IconSizes.floating;

  Alignment? _drag;

  /// Where the finger is in the overlay, while it drags.
  Offset? _at;

  bool get _docking =>
      widget.onDock != null &&
      (_at?.dx ?? double.infinity) < NavigationLift.dockZone;

  void _dragTo(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final at = box.globalToLocal(globalPosition);
    final fraction = tabBarCornerDragFraction(
      at,
      area: box.size,
      buttonSize: _buttonSize,
      margin: _margin,
    );
    setState(() {
      _at = at;
      _drag = Alignment(fraction.dx, fraction.dy);
    });
  }

  void _release() {
    final drag = _drag;
    if (drag == null) return;
    final docking = _docking;
    final at = _at;
    final box = context.findRenderObject();
    setState(() {
      _drag = null;
      _at = null;
    });
    if (docking && at != null && box is RenderBox && box.hasSize) {
      widget.onDock?.call((at.dy / box.size.height).clamp(0.0, 1.0));
      return;
    }
    widget.onCornerChosen(tabBarCornerNearest(drag.x, y: drag.y));
  }

  @override
  Widget build(BuildContext context) {
    final corner = widget.corner;
    final scheme = Theme.of(context).colorScheme;
    final button = Padding(
      padding: const EdgeInsets.all(_margin),
      child: AnimatedAlign(
        alignment:
            _drag ??
            Alignment(
              tabBarCornerIsRight(corner) ? 1 : -1,
              tabBarCornerIsTop(corner) ? -1 : 1,
            ),
        duration: _drag != null ? Duration.zero : Motion.settle,
        curve: Curves.easeOutCubic,
        child: TabBarCornerButton(
          dragging: _drag != null,
          onTap: widget.onTap,
          onDragBegin: (globalPosition) {
            unawaited(HapticFeedback.mediumImpact());
            _dragTo(globalPosition);
          },
          onDragUpdate: _dragTo,
          onDragEnd: _release,
        ),
      ),
    );
    // One tree while dragging and not, so the button's drag survives.
    final at = _at;
    final lifted = widget.onDock != null && _drag != null && at != null;
    return LayoutBuilder(
      builder: (context, box) => Stack(
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Visibility(
              visible: lifted,
              child: DockZone(hot: _docking),
            ),
          ),
          Positioned.fill(
            child: Opacity(opacity: _docking ? 0 : 1, child: button),
          ),
          Positioned(
            left: 0,
            top: ((at?.dy ?? 0) - SidebarArrowTab.size.height / 2).clamp(
              0,
              (box.maxHeight - SidebarArrowTab.size.height)
                  .clamp(0, double.infinity),
            ),
            child: Visibility(
              visible: _docking,
              child: IgnorePointer(
                child: ArrowTabFace(
                  color: scheme.primary,
                  onColor: scheme.onPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
