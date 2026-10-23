import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/remote_focus.dart';
import 'package:webspace/theme/design_tokens.dart';

/// The app's chrome where a TV remote drives the device (NAV-016), around
/// the navigator so dialogs, sheets and menus have it too: Up and Down leave
/// a one-line text field, whose caret would otherwise keep every arrow, and
/// an outline marks whatever has focus. Built only where a remote drives it.
class RemoteControls extends StatelessWidget {
  const RemoteControls({super.key, required this.child});

  final Widget child;

  @visibleForTesting
  static const ringKey = ValueKey('remote-focus-ring');

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.arrowUp): _LeaveField(
        TraversalDirection.up,
      ),
      SingleActivator(LogicalKeyboardKey.arrowDown): _LeaveField(
        TraversalDirection.down,
      ),
    },
    child: Actions(
      actions: {_LeaveField: _LeaveFieldAction()},
      child: Stack(
        fit: StackFit.passthrough,
        alignment: Alignment.topLeft,
        children: [child, const _FocusRing()],
      ),
    ),
  );
}

class _LeaveField extends Intent {
  const _LeaveField(this.direction);

  final TraversalDirection direction;
}

/// Enabled only in a one-line text field, so every other key goes on to the
/// field's own caret moves or to the app's focus moves.
class _LeaveFieldAction extends Action<_LeaveField> {
  @override
  bool isEnabled(_LeaveField intent) {
    final field = FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>();
    return field != null && field.widget.maxLines == 1;
  }

  @override
  void invoke(_LeaveField intent) =>
      FocusManager.instance.primaryFocus?.focusInDirection(intent.direction);
}

class _FocusRing extends StatefulWidget {
  const _FocusRing();

  @override
  State<_FocusRing> createState() => _FocusRingState();
}

class _FocusRingState extends State<_FocusRing> {
  Rect? _rect;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_changed);
    FocusManager.instance.addHighlightModeListener(_modeChanged);
    _changed();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_changed);
    FocusManager.instance.removeHighlightModeListener(_modeChanged);
    super.dispose();
  }

  void _modeChanged(FocusHighlightMode mode) => _changed();

  void _changed() {
    _arm();
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  /// Measures after the next frame, and after every frame while a ring
  /// shows, so it follows a control that scrolls or animates. A post-frame
  /// callback asks for no frame of its own, so an idle screen stays idle.
  void _arm() {
    if (_armed) return;
    _armed = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _armed = false;
      if (!mounted) return;
      final rect = _measure();
      if (rect != _rect) setState(() => _rect = rect);
      if (rect != null) _arm();
    });
  }

  Rect? _measure() {
    final manager = FocusManager.instance;
    if (manager.highlightMode != FocusHighlightMode.traditional) return null;
    final node = manager.primaryFocus;
    final focused = node?.context;
    if (node is FocusScopeNode || focused == null || !focused.mounted) {
      return null;
    }
    if (OwnFocusOutline.covers(focused)) return null;
    final target = focused.findRenderObject();
    final stack = context.findAncestorRenderObjectOfType<RenderStack>();
    if (target is! RenderBox ||
        stack == null ||
        !target.attached ||
        !target.hasSize) {
      return null;
    }
    final rect = MatrixUtils.transformRect(
      target.getTransformTo(stack),
      Offset.zero & target.size,
    );
    return rect.isEmpty ? null : rect;
  }

  @override
  Widget build(BuildContext context) {
    final rect = _rect;
    if (rect == null) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }
    final scheme = Theme.of(context).colorScheme;
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: DecoratedBox(
          key: RemoteControls.ringKey,
          decoration: BoxDecoration(
            border: Border.all(
              color: scheme.primary,
              width: RemoteStyle.ringWidth,
            ),
            borderRadius: BorderRadius.circular(RemoteStyle.ringRadius),
          ),
          child: Padding(
            padding: const EdgeInsets.all(RemoteStyle.ringWidth),
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(
                  color: scheme.surface,
                  width: RemoteStyle.ringInner,
                ),
                borderRadius: BorderRadius.circular(
                  RemoteStyle.ringRadius - RemoteStyle.ringWidth,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
