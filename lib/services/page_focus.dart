import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/keyboard_input.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/services/page_shim.dart';
import 'package:webspace/services/remote_input.dart';

const kRemoteEdgeHandler = 'wsRemoteEdge';

const _dpad = [
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
];

/// What drives a site page on Android while it has focus. Flutter takes
/// every key before the webview and spends some of them on moving its own
/// focus, the arrows and Tab, so without a [PageFocus] the page never sees
/// those.
enum PageKeys {
  /// A TV remote's D-pad (NAV-016): the D-pad goes on to the webview, and an
  /// arrow the page had no use for moves focus out of it.
  remote,

  /// A keyboard (NAV-019): every key the shortcuts left goes on to the
  /// webview, as Linux's keeps every key it is given.
  keyboard;

  /// The host's: a remote's where one drives the device, else a keyboard's,
  /// which may be attached at any time; none off Android.
  static PageKeys? get host {
    if (!hostIsAndroid) return null;
    return RemoteInput.driven ? remote : keyboard;
  }

  bool keeps(LogicalKeyboardKey key) => switch (this) {
        remote => _dpad.contains(key),
        keyboard => true,
      };

  /// Whether focus entering the page gives the webview native focus, which
  /// a Flutter focus move alone does not. Without a keyboard focus enters
  /// the page only by a touch, which focuses the view itself.
  bool get focusesView => switch (this) {
        remote => true,
        keyboard => KeyboardInput.attached.value,
      };
}

/// A site page on Android as [keys] drive it: while it has focus they go on
/// to the webview; focus entering it gives the native view focus; and, for a
/// remote, an arrow the page had no use for ([PageJs.remoteEdge], in
/// whichever of its frames had focus) moves focus out of it, toward the app
/// bar or the tab strip.
final class PageFocus {
  @visibleForTesting
  PageFocus({required this.keys});

  final PageKeys keys;

  /// The focus of a site page as [keys] drive it, a remote's page script
  /// added [into] the page's scripts; null where nothing does.
  static PageFocus? install({
    required PageKeys? keys,
    required List<inapp.UserScript> into,
  }) {
    if (keys == null) return null;
    switch (keys) {
      case PageKeys.remote:
        into.add(pageShim(
          'remote_edge',
          js: PageJs.remoteEdge.withConfig({'handler': kRemoteEdgeHandler}),
          frames: ShimFrames.all,
        ));
      case PageKeys.keyboard:
        break;
    }
    return PageFocus(keys: keys);
  }

  Future<void> Function()? _focusView;
  bool _hasFocus = false;
  LogicalKeyboardKey? _unanswered;

  /// Answers a remote's page script, and focuses [view] as focus enters.
  void attach(inapp.InAppWebViewController view) {
    switch (keys) {
      case PageKeys.remote:
        view.addJavaScriptHandler(
          handlerName: kRemoteEdgeHandler,
          callback: (inapp.JavaScriptHandlerFunctionData data) {
            if (data.isMainFrame) leave(edgeOf(data.args));
            return null;
          },
        );
      case PageKeys.keyboard:
        break;
    }
    bind(focusView: () async {
      try {
        await view.requestFocus();
      } on PlatformException {
        // The view is going; the next time focus enters asks again.
      } on MissingPluginException {
        // Same: its channel went with it.
      }
    });
  }

  @visibleForTesting
  void bind({required Future<void> Function() focusView}) {
    _focusView = focusView;
    if (_hasFocus && keys.focusesView) unawaited(focusView());
  }

  /// The direction the page script names in [args], or null.
  static TraversalDirection? edgeOf(List<dynamic> args) => switch (args) {
        [final String name] => TraversalDirection.values.asNameMap()[name],
        _ => null,
      };

  /// Moves focus out of the page toward [direction], where the page has it
  /// and the last D-pad key it was handed is that arrow: one move per press,
  /// so a frame that reports an arrow nobody pressed moves nothing.
  void leave(TraversalDirection? direction) {
    if (direction == null || !_hasFocus) return;
    if (_unanswered != _arrow(direction)) return;
    _unanswered = null;
    FocusManager.instance.primaryFocus?.focusInDirection(direction);
  }

  static LogicalKeyboardKey _arrow(TraversalDirection direction) =>
      switch (direction) {
        TraversalDirection.up => LogicalKeyboardKey.arrowUp,
        TraversalDirection.down => LogicalKeyboardKey.arrowDown,
        TraversalDirection.left => LogicalKeyboardKey.arrowLeft,
        TraversalDirection.right => LogicalKeyboardKey.arrowRight,
      };

  Widget wrap(Widget page) => OwnFocusOutline(
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (hasFocus) {
            _hasFocus = hasFocus;
            if (hasFocus && keys.focusesView) unawaited(_focusView?.call());
          },
          onKeyEvent: (node, event) {
            if (!keys.keeps(event.logicalKey)) return KeyEventResult.ignored;
            if (event is KeyDownEvent) _unanswered = event.logicalKey;
            return KeyEventResult.skipRemainingHandlers;
          },
          child: page,
        ),
      );
}

/// A subtree that shows its own focus, so the remote's focus outline is not
/// drawn over it (NAV-016): a site page, whose engine outlines the link it
/// has focused, and a launcher icon, which outlines itself.
class OwnFocusOutline extends InheritedWidget {
  const OwnFocusOutline({super.key, required super.child});

  static bool covers(BuildContext context) =>
      context.getInheritedWidgetOfExactType<OwnFocusOutline>() != null;

  @override
  bool updateShouldNotify(OwnFocusOutline oldWidget) => false;
}
