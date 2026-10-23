import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
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

/// A site page driven by a TV remote's D-pad (NAV-016). Flutter takes every
/// key before the webview and spends the arrows on moving its own focus, so
/// without this the D-pad never reaches the page. While the page has focus
/// the D-pad goes on to the webview; focus entering it gives the native view
/// focus, which a Flutter focus move alone does not; and an arrow the page
/// had no use for ([PageJs.remoteEdge]) moves focus out of it, toward the
/// app bar or the tab strip.
final class RemoteFocus {
  @visibleForTesting
  RemoteFocus();

  /// The focus of a site page where a remote drives the device, its page
  /// script added [into] the page's scripts; null on any other device.
  static RemoteFocus? install({required List<inapp.UserScript> into}) {
    if (!RemoteInput.driven) return null;
    into.add(pageShim(
      'remote_edge',
      js: PageJs.remoteEdge.withConfig({'handler': kRemoteEdgeHandler}),
      frames: ShimFrames.top,
    ));
    return RemoteFocus();
  }

  Future<void> Function()? _focusView;
  bool _hasFocus = false;

  /// Answers the page script, and focuses [view] whenever focus enters it.
  void attach(inapp.InAppWebViewController view) {
    view.addJavaScriptHandler(
      handlerName: kRemoteEdgeHandler,
      callback: (inapp.JavaScriptHandlerFunctionData data) {
        if (data.isMainFrame) leave(edgeOf(data.args));
        return null;
      },
    );
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
    if (_hasFocus) unawaited(focusView());
  }

  /// The direction the page script names in [args], or null.
  static TraversalDirection? edgeOf(List<dynamic> args) => switch (args) {
        [final String name] => TraversalDirection.values.asNameMap()[name],
        _ => null,
      };

  /// Moves focus out of the page toward [direction], where the page has it.
  void leave(TraversalDirection? direction) {
    if (direction == null || !_hasFocus) return;
    FocusManager.instance.primaryFocus?.focusInDirection(direction);
  }

  Widget wrap(Widget page) => OwnFocusOutline(
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (hasFocus) {
            _hasFocus = hasFocus;
            if (hasFocus) unawaited(_focusView?.call());
          },
          onKeyEvent: (node, event) => _dpad.contains(event.logicalKey)
              ? KeyEventResult.skipRemainingHandlers
              : KeyEventResult.ignored,
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
