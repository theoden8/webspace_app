import 'package:flutter/material.dart';

/// Floating circular button that reveals the tab strip on demand.
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
        scale: dragging ? 1.2 : 1.0,
        duration: const Duration(milliseconds: 100),
        child: Material(
          color: Theme.of(context).colorScheme.primary.withOpacity(0.85),
          shape: const CircleBorder(),
          elevation: dragging ? 8 : 3,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(
                Icons.tab,
                size: 22,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
