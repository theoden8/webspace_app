import 'package:flutter/gestures.dart' show kSecondaryButton, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/theme/design_tokens.dart';

/// An icon in a launcher grid, pressed as a phone's home screen is: a tap
/// opens it; a long press lifts it under the finger, and letting go where it
/// was opens its menu, while moving it drags it onto another icon of its
/// kind, which takes its place (WEBSPACE-011). A secondary click opens the
/// menu too.
class LauncherLift<T extends Object> extends StatefulWidget {
  const LauncherLift({
    super.key,
    required this.data,
    required this.onOpen,
    required this.onMenu,
    required this.onDrop,
    required this.child,
  });

  /// What a drag of this icon carries; null for one that lifts only for its
  /// menu, as "All" does, which never moves.
  final T? data;
  final VoidCallback onOpen;

  /// The icon's menu, at a global position.
  final ValueChanged<Offset> onMenu;

  /// Another icon's [data] dropped on this one; null where the grid cannot
  /// be reordered, so nothing lands here and a lifted icon only opens its
  /// menu.
  final ValueChanged<T>? onDrop;
  final Widget child;

  @override
  State<LauncherLift<T>> createState() => _LauncherLiftState<T>();
}

class _LauncherLiftState<T extends Object> extends State<LauncherLift<T>> {
  PointerDownEvent? _down;
  Offset? _liftedAt;
  bool _pressed = false;
  bool _focused = false;

  void _press({required bool down}) {
    if (_pressed != down) setState(() => _pressed = down);
  }

  Offset get _center {
    final box = context.findRenderObject()! as RenderBox;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final onDrop = widget.onDrop;
    return Semantics(
      button: true,
      onTap: widget.onOpen,
      onLongPress: () => widget.onMenu(_center),
      child: FocusableActionDetector(
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onOpen();
              return null;
            },
          ),
        },
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.contextMenu): _MenuIntent(),
        },
        child: Actions(
          actions: {
            _MenuIntent: CallbackAction<_MenuIntent>(
              onInvoke: (_) {
                widget.onMenu(_center);
                return null;
              },
            ),
          },
          child: DragTarget<T>(
            onWillAcceptWithDetails: (details) =>
                onDrop != null && details.data != widget.data,
            onAcceptWithDetails: (details) => onDrop!(details.data),
            builder: (context, candidates, _) => LayoutBuilder(
              builder: (context, constraints) => LongPressDraggable<T>(
                data: widget.data,
                hapticFeedbackOnStart: true,
                onDragStarted: () {
                  _liftedAt = _down?.position;
                  _down = null;
                  _press(down: false);
                },
                onDraggableCanceled: (_, offset) => _settle(at: offset),
                onDragCompleted: () => _liftedAt = null,
                feedback: _Lifted(
                  size: constraints.biggest,
                  animate: !reduceMotion,
                  child: widget.child,
                ),
                childWhenDragging: Opacity(
                  opacity: LibraryStyle.dragGhost,
                  child: widget.child,
                ),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  // A raw Listener, not a tap recognizer: the gesture arena
                  // against LongPressDraggable delays or drops taps.
                  onPointerDown: (event) {
                    if (event.buttons == kSecondaryButton) {
                      widget.onMenu(event.position);
                      return;
                    }
                    _down = event;
                    _press(down: true);
                  },
                  onPointerMove: (event) {
                    final at = _down;
                    if (at != null &&
                        (event.position - at.position).distance > kTouchSlop) {
                      _press(down: false);
                    }
                  },
                  onPointerUp: (event) {
                    final at = _down;
                    _down = null;
                    _press(down: false);
                    // Any press let go before it lifts is a tap: a lift
                    // clears [_down] as it begins.
                    if (at != null &&
                        (event.position - at.position).distance < kTouchSlop) {
                      widget.onOpen();
                    }
                  },
                  onPointerCancel: (_) {
                    _down = null;
                    _press(down: false);
                  },
                  child: AnimatedScale(
                    scale: _pressed ? LibraryStyle.pressScale : 1,
                    duration: reduceMotion ? Duration.zero : Motion.press,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(
                          LibraryStyle.radius,
                        ),
                        border: candidates.isNotEmpty || _focused
                            ? Border.all(
                                color: theme.colorScheme.primary,
                                width: LibraryStyle.selectionWidth,
                              )
                            : null,
                      ),
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// A lift that ends without landing, its feedback's corner [at]: let go
  /// where it was, it opens the menu there; anywhere else it returns to its
  /// place.
  void _settle({required Offset at}) {
    final lifted = _liftedAt;
    _liftedAt = null;
    if (lifted == null || !mounted) return;
    final box = context.findRenderObject()! as RenderBox;
    final moved = at - box.localToGlobal(Offset.zero);
    if (moved.distance < kTouchSlop) widget.onMenu(lifted + moved);
  }
}

class _MenuIntent extends Intent {
  const _MenuIntent();
}

/// The icon raised under the finger: a little larger, over a shadow.
class _Lifted extends StatelessWidget {
  const _Lifted({required this.size, required this.animate, required this.child});

  final Size size;
  final bool animate;
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: animate ? Motion.lift : Duration.zero,
    curve: Curves.easeOutBack,
    // On a platter, as a phone lifts an icon to show its menu.
    builder: (context, t, child) => Transform.scale(
      scale: 1 + (LibraryStyle.liftScale - 1) * t,
      child: Material(
        color: Theme.of(context).colorScheme.surface,
        elevation: Elevations.floatingActive * t.clamp(0.0, 1.0),
        borderRadius: BorderRadius.circular(LibraryStyle.radius),
        child: child,
      ),
    ),
    child: SizedBox.fromSize(size: size, child: child),
  );
}
