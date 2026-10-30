import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/theme/design_tokens.dart';

/// The app's chrome where a TV remote drives the device (NAV-016), around
/// the navigator so dialogs, sheets and menus have it too: Up and Down leave
/// a one-line text field, whose caret would otherwise keep every arrow; the
/// on-screen keyboard waits for OK in a field ([_Keyboard]); and an outline
/// marks whatever has focus. It runs in Flutter's directional navigation,
/// which Flutter never picks itself: a slider then leaves Up and Down to
/// moving focus instead of taking them as a change of its value, and a
/// disabled control still takes focus, so the D-pad can rest on it. Built
/// only where a remote drives it.
class RemoteControls extends StatefulWidget {
  const RemoteControls({super.key, required this.child});

  final Widget child;

  @visibleForTesting
  static const ringKey = ValueKey('remote-focus-ring');

  @override
  State<RemoteControls> createState() => _RemoteControlsState();
}

class _RemoteControlsState extends State<RemoteControls> {
  final _keyboard = _Keyboard();

  @override
  void initState() {
    super.initState();
    _keyboard.start();
  }

  @override
  void dispose() {
    _keyboard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      navigationMode: NavigationMode.directional,
    ),
    child: Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.arrowUp): _LeaveField(
          TraversalDirection.up,
        ),
        SingleActivator(LogicalKeyboardKey.arrowDown): _LeaveField(
          TraversalDirection.down,
        ),
        SingleActivator(LogicalKeyboardKey.select): _Type(),
        SingleActivator(LogicalKeyboardKey.enter): _Type(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _Type(),
      },
      child: Actions(
        actions: {
          _LeaveField: _LeaveFieldAction(),
          _Type: _TypeAction(_keyboard),
        },
        child: Stack(
          fit: StackFit.passthrough,
          alignment: Alignment.topLeft,
          children: [widget.child, const _FocusRing()],
        ),
      ),
    ),
  );
}

/// The text field that has focus, if one does.
EditableTextState? _focusedField() => FocusManager.instance.primaryFocus
    ?.context
    ?.findAncestorStateOfType<EditableTextState>();

class _LeaveField extends Intent {
  const _LeaveField(this.direction);

  final TraversalDirection direction;
}

/// Enabled only in a one-line text field, so every other key goes on to the
/// field's own caret moves or to the app's focus moves.
class _LeaveFieldAction extends Action<_LeaveField> {
  @override
  bool isEnabled(_LeaveField intent) {
    final field = _focusedField();
    return field != null && field.widget.maxLines == 1;
  }

  @override
  void invoke(_LeaveField intent) =>
      FocusManager.instance.primaryFocus?.focusInDirection(intent.direction);
}

class _Type extends Intent {
  const _Type();
}

/// OK in a text field that takes typing brings the keyboard up for it; any
/// other OK goes on to what has focus.
class _TypeAction extends Action<_Type> {
  _TypeAction(this._keyboard);

  final _Keyboard _keyboard;

  @override
  bool isEnabled(_Type intent) {
    final field = _focusedField();
    return field != null && !field.widget.readOnly;
  }

  @override
  void invoke(_Type intent) {
    if (_focusedField() case final field?) _keyboard.open(field);
  }
}

/// The on-screen keyboard where a remote drives the device: it stays down as
/// focus lands on a text field, so the D-pad passes over a field as over any
/// control, and comes up when OK is pressed in one, for that field until
/// focus leaves it. Every focus request hands a field the keyboard, so the
/// gate is the input control: while [_quiet] is current the platform is told
/// the field takes none.
final class _Keyboard {
  final _quiet = _QuietInput();
  FocusNode? _typing;

  void start() => TextInput.setInputControl(_quiet);

  void dispose() {
    _typing?.removeListener(_left);
    _typing = null;
    TextInput.restorePlatformInputControl();
  }

  void open(EditableTextState field) {
    final node = field.widget.focusNode;
    if (_typing != node) {
      _typing?.removeListener(_left);
      _typing = node..addListener(_left);
      TextInput.restorePlatformInputControl();
      // The field attached while the platform was told it takes no keyboard,
      // and nothing in the framework sends its configuration again.
      unawaited(_configure(field.textInputConfiguration));
    }
    field.requestKeyboard();
  }

  /// Runs before a field that focus lands on attaches: the node focus leaves
  /// is told first, so that field opens no keyboard either.
  void _left() {
    final typing = _typing;
    if (typing == null || typing.hasFocus) return;
    typing.removeListener(_left);
    _typing = null;
    TextInput.setInputControl(_quiet);
  }

  static Future<void> _configure(TextInputConfiguration configuration) async {
    try {
      await SystemChannels.textInput.invokeMethod<void>(
        'TextInput.updateConfig',
        configuration.toJson(),
      );
    } on PlatformException catch (e) {
      LogTag.navigation.error('Keyboard configuration refused: ${e.code}');
    }
  }
}

/// An input control that shows nothing.
class _QuietInput with TextInputControl {}

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
