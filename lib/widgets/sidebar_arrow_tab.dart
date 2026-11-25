import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/back_swipe_exclusion.dart';
import 'package:webspace/settings/demo_mode.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/toast.dart';

/// A hold of the arrow tab and where the finger takes it, in global
/// coordinates: lifted, moved, let go, or given up (TAB-038).
typedef ArrowLift = ({
  ValueChanged<Offset> onLift,
  ValueChanged<Offset> onMove,
  ValueChanged<Offset> onDrop,
  VoidCallback onCancel,
});

/// The small tab on the left edge that brings a closed sidebar back: a tap
/// brings it back as it was left; a drag right pulls it out under the
/// finger; a drag up or down moves the tab along the edge. On Android it
/// keeps its own strip of the edge from the system back swipe (TAB-032). A
/// hold lifts it, to be dropped on the page as the site strip's button
/// (TAB-038); the first time one shows, a message says so.
class SidebarArrowTab extends StatefulWidget {
  const SidebarArrowTab({
    super.key,
    required this.onTap,
    required this.onPull,
    required this.onPullEnd,
    required this.onMove,
    required this.onMoveEnd,
    this.lift,
    this.exclusion,
  });

  static const Size size = Size(18, 60);

  final VoidCallback onTap;

  /// How far right the drag has come.
  final ValueChanged<double> onPull;
  final VoidCallback onPullEnd;

  /// How far down the drag has come (up is negative).
  final ValueChanged<double> onMove;
  final VoidCallback onMoveEnd;

  /// A hold of the tab; null where it cannot be lifted.
  final ArrowLift? lift;

  /// Where the tab claims its strip of the edge; the app's own by default.
  final BackSwipeExclusion? exclusion;

  @override
  State<SidebarArrowTab> createState() => _SidebarArrowTabState();
}

enum _Drag { none, pull, move }

class _SidebarArrowTabState extends State<SidebarArrowTab> {
  _Drag _drag = _Drag.none;
  Offset _travelled = Offset.zero;

  BackSwipeExclusion get _exclusion =>
      widget.exclusion ?? BackSwipeExclusion.instance;

  /// Claims the strip the tab was laid out on, in the window's device pixels.
  void _claim() {
    if (!mounted) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final ratio = View.of(context).devicePixelRatio;
    final rect = (box.localToGlobal(Offset.zero) & box.size);
    unawaited(_exclusion.keep(Rect.fromLTRB(rect.left * ratio,
        rect.top * ratio, rect.right * ratio, rect.bottom * ratio)));
  }

  @override
  void initState() {
    super.initState();
    if (widget.lift != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger == null) return;
        unawaited(ArrowDragHint.maybeShow(
          messenger,
          message: AppLocalizations.of(context).sidebarArrowDragHint,
        ));
      });
    }
  }

  @override
  void dispose() {
    unawaited(_exclusion.release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _claim());
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: AppLocalizations.of(context).sidebarShow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onPanStart: (_) {
          _drag = _Drag.none;
          _travelled = Offset.zero;
        },
        onPanUpdate: (d) {
          _travelled += d.delta;
          if (_drag == _Drag.none && _travelled.distance > 6) {
            _drag = _travelled.dx.abs() > _travelled.dy.abs()
                ? _Drag.pull
                : _Drag.move;
          }
          switch (_drag) {
            case _Drag.pull:
              widget.onPull(_travelled.dx.clamp(0, double.infinity));
            case _Drag.move:
              widget.onMove(_travelled.dy);
            case _Drag.none:
              break;
          }
        },
        onLongPressStart: switch (widget.lift) {
          final lift? => (d) {
              unawaited(HapticFeedback.mediumImpact());
              lift.onLift(d.globalPosition);
            },
          null => null,
        },
        onLongPressMoveUpdate: switch (widget.lift) {
          final lift? => (d) => lift.onMove(d.globalPosition),
          null => null,
        },
        onLongPressEnd: switch (widget.lift) {
          final lift? => (d) => lift.onDrop(d.globalPosition),
          null => null,
        },
        onLongPressCancel: widget.lift?.onCancel,
        onPanEnd: (_) {
          switch (_drag) {
            case _Drag.pull:
              widget.onPullEnd();
            case _Drag.move:
              widget.onMoveEnd();
            case _Drag.none:
              break;
          }
          _drag = _Drag.none;
        },
        child: ArrowTabFace(color: scheme.primary, onColor: scheme.onPrimary),
      ),
    );
  }
}

/// How the arrow tab looks, on the edge or lifted.
class ArrowTabFace extends StatelessWidget {
  const ArrowTabFace({super.key, required this.color, required this.onColor});

  final Color color;
  final Color onColor;

  @override
  Widget build(BuildContext context) => Material(
        color: color,
        elevation: 3,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            right: Radius.circular(Radii.xl),
          ),
        ),
        child: SizedBox(
          width: SidebarArrowTab.size.width,
          height: SidebarArrowTab.size.height,
          child: Icon(Icons.chevron_right, size: 16, color: onColor),
        ),
      );
}

/// The strip along the left edge a lifted control docks in, lit while it
/// would (TAB-038).
class DockZone extends StatelessWidget {
  const DockZone({super.key, required this.hot});

  final bool hot;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: AnimatedOpacity(
        duration: Motion.press,
        opacity: hot ? 1 : 0.5,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: color, width: 3)),
            gradient: LinearGradient(
              colors: [color.withValues(alpha: 0.3), color.withValues(alpha: 0)],
            ),
          ),
          child: const SizedBox(width: NavigationLift.dockZone),
        ),
      ),
    );
  }
}

/// The message, once per install, that the arrow tab can be dragged onto the
/// page for the site strip (TAB-038), remembered in SharedPreferences.
abstract final class ArrowDragHint {
  static const String shownKey = 'sidebarArrowDragHintShown';
  static bool _asked = false;

  @visibleForTesting
  static void forget() => _asked = false;

  static Future<void> maybeShow(
    ScaffoldMessengerState messenger, {
    required Localized message,
  }) async {
    if (_asked || isDemoMode) return;
    _asked = true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(shownKey) ?? false) return;
    await prefs.setBool(shownKey, true);
    if (!messenger.mounted) return;
    messenger.toast(message, duration: const Duration(seconds: 6));
  }
}
