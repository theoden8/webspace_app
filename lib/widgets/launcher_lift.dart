import 'package:flutter/gestures.dart' show kSecondaryButton, kTouchSlop;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/launcher_grid.dart';
import 'package:webspace/widgets/launcher_slot.dart';

/// An icon in a launcher grid, pressed as a phone's home screen is: a tap
/// opens it; a long press lifts it under the finger, and letting go where it
/// was opens its menu, while moving it drags it through its [LauncherGrid],
/// which makes room where it hovers and keeps it where it is let go
/// (WEBSPACE-011). A secondary click opens the menu too. A key presses it the
/// same way: OK or Enter let go opens it, held opens its menu, which is how a
/// TV remote, with no long press or Menu key, reaches the menu (NAV-016).
class LauncherLift<T extends Object> extends StatefulWidget {
  const LauncherLift({
    super.key,
    required this.data,
    required this.onOpen,
    required this.onMenu,
    required this.child,
  });

  /// What a drag of this icon carries; null for one that lifts only for its
  /// menu, as "All" does, which never moves.
  final T? data;
  final VoidCallback onOpen;

  /// The icon's menu, at a global position.
  final ValueChanged<Offset> onMenu;
  final Widget child;

  @override
  State<LauncherLift<T>> createState() => _LauncherLiftState<T>();
}

class _LauncherLiftState<T extends Object> extends State<LauncherLift<T>> {
  PointerDownEvent? _down;
  bool _pressed = false;
  bool _focused = false;

  /// Where the finger lifted the icon, and the icon's corner then.
  ({Offset finger, Offset corner})? _lifted;

  /// Whether the lifted icon went further than a tap's slop: then letting go
  /// moves it, wherever that is, and never opens the menu.
  bool _wandered = false;

  /// The key pressing the icon, and whether holding it opened the menu.
  ({LogicalKeyboardKey key, bool held})? _keyPress;

  static const _pressKeys = [
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  ];

  KeyEventResult _onKey(KeyEvent event) {
    if (!_pressKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    final press = _keyPress;
    final same = press != null && press.key == event.logicalKey;
    switch (event) {
      case KeyDownEvent():
        _keyPress = (key: event.logicalKey, held: false);
        _press(down: true);
      case KeyRepeatEvent():
        if (same && !press.held) {
          _keyPress = (key: press.key, held: true);
          _press(down: false);
          widget.onMenu(_center);
        }
      case KeyUpEvent():
        _keyPress = null;
        _press(down: false);
        if (same && !press.held) widget.onOpen();
    }
    return KeyEventResult.handled;
  }

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
    final lift = Semantics(
      button: true,
      onTap: widget.onOpen,
      onLongPress: () => widget.onMenu(_center),
      child: FocusableActionDetector(
        // A key let go after focus left presses nothing.
        onFocusChange: (focused) {
          if (focused) return;
          _keyPress = null;
          _press(down: false);
        },
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
          child: LayoutBuilder(
            builder: (context, constraints) => LongPressDraggable<T>(
              data: widget.data,
              hapticFeedbackOnStart: true,
              onDragStarted: () {
                final box = context.findRenderObject()! as RenderBox;
                _lifted = (
                  finger: _down?.position ?? box.size.center(Offset.zero),
                  corner: box.localToGlobal(Offset.zero),
                );
                _wandered = false;
                _down = null;
                _press(down: false);
              },
              onDragUpdate: (details) {
                final lifted = _lifted;
                if (lifted != null &&
                    (details.globalPosition - lifted.finger).distance >
                        kTouchSlop) {
                  _wandered = true;
                }
              },
              onDragEnd: (details) => _settle(at: details.offset),
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
                      borderRadius: BorderRadius.circular(LibraryStyle.radius),
                      border: _focused
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
    );
    return OwnFocusOutline(
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (_, event) => _onKey(event),
        child: lift,
      ),
    );
  }

  /// A lift let go with the icon's corner at [at]. If it never wandered it
  /// opens the menu where it was; otherwise the grid keeps it where it was
  /// shown, and it lands there from where it was let go.
  void _settle({required Offset at}) {
    final lifted = _lifted;
    _lifted = null;
    if (lifted == null || !mounted) return;
    if (!_wandered && (at - lifted.corner).distance < kTouchSlop) {
      widget.onMenu(lifted.finger + (at - lifted.corner));
      return;
    }
    LauncherSlot.maybeOf(context)?.landFrom(at);
    final data = widget.data;
    if (data != null) LauncherGrid.dragEnded<T>(context, id: data);
  }
}

class _MenuIntent extends Intent {
  const _MenuIntent();
}

/// The icon raised under the finger: a little larger, over a shadow.
class _Lifted extends StatelessWidget {
  const _Lifted({
    required this.size,
    required this.animate,
    required this.child,
  });

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
