import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/theme/design_tokens.dart';

/// The small tab on the left edge that brings a closed sidebar back: a tap
/// brings it back as it was left; a drag right pulls it out under the
/// finger; a drag up or down moves the tab along the edge.
class SidebarArrowTab extends StatefulWidget {
  const SidebarArrowTab({
    super.key,
    required this.onTap,
    required this.onPull,
    required this.onPullEnd,
    required this.onMove,
    required this.onMoveEnd,
  });

  static const Size size = Size(18, 60);

  final VoidCallback onTap;

  /// How far right the drag has come.
  final ValueChanged<double> onPull;
  final VoidCallback onPullEnd;

  /// How far down the drag has come (up is negative).
  final ValueChanged<double> onMove;
  final VoidCallback onMoveEnd;

  @override
  State<SidebarArrowTab> createState() => _SidebarArrowTabState();
}

enum _Drag { none, pull, move }

class _SidebarArrowTabState extends State<SidebarArrowTab> {
  _Drag _drag = _Drag.none;
  Offset _travelled = Offset.zero;

  @override
  Widget build(BuildContext context) {
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
        child: Material(
          color: scheme.primary,
          elevation: 3,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.horizontal(
              right: Radius.circular(Radii.xl),
            ),
          ),
          child: SizedBox(
            width: SidebarArrowTab.size.width,
            height: SidebarArrowTab.size.height,
            child: Icon(Icons.chevron_right, size: 16, color: scheme.onPrimary),
          ),
        ),
      ),
    );
  }
}
