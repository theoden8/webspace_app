import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

/// The slice of [inapp.PullToRefreshController] the gate drives, kept as an
/// interface so the state machine can be exercised without a platform channel.
abstract class RefreshControl {
  Future<void> setEnabled(bool enabled);
  Future<void> endRefreshing();
}

class _ControllerRefreshControl implements RefreshControl {
  _ControllerRefreshControl(this._controller);

  final inapp.PullToRefreshController _controller;

  @override
  Future<void> setEnabled(bool enabled) => _controller.setEnabled(enabled);

  @override
  Future<void> endRefreshing() => _controller.endRefreshing();
}

/// Keeps a two-finger pinch from firing pull-to-refresh (NAV-006).
///
/// Neither platform's refresh control is multi-touch aware: Android's
/// `SwipeRefreshLayout` follows a single pointer and never consults
/// `getPointerCount()`, so a pinch that starts with the page at scroll top
/// reads as a downward drag, and iOS's `UIRefreshControl` sees the same thing
/// through the scroll view's simultaneous two-finger pan. Neither exposes a
/// knob for it, so the gate watches Flutter's own pointer stream (which sees
/// every touch over the platform view before the native view does) and:
///
///  1. disables the control the moment a second pointer lands, which lands
///     ahead of the native drag passing its touch slop, and
///  2. swallows an `onRefresh` that beat step 1, so losing that race costs a
///     spinner rather than a page reload.
class PullToRefreshGate {
  PullToRefreshGate._(this._control, this.controller, this._now);

  /// Builds the refresh controller together with the gate guarding it.
  factory PullToRefreshGate.create({
    required Future<void> Function() onRefresh,
  }) {
    late final PullToRefreshGate gate;
    final controller = inapp.PullToRefreshController(
      settings: inapp.PullToRefreshSettings(enabled: true),
      onRefresh: () => gate.runRefresh(onRefresh),
    );
    gate = PullToRefreshGate._(
      _ControllerRefreshControl(controller),
      controller,
      DateTime.now,
    );
    return gate;
  }

  /// Test seam: a gate over a fake control and clock, with no platform channel
  /// and no controller of its own.
  PullToRefreshGate.forControl(
    RefreshControl control, {
    DateTime Function() now = DateTime.now,
  })  : _control = control,
        controller = null,
        _now = now;

  /// A refresh arriving this soon after the last finger of a pinch lifted is
  /// still that pinch: the native control fires on release and the event
  /// crosses the platform channel after Flutter has seen the pointer up.
  static const Duration _multiTouchGrace = Duration(milliseconds: 600);

  final RefreshControl _control;
  final DateTime Function() _now;

  /// The controller to hand to `InAppWebView`, or null for a test gate.
  final inapp.PullToRefreshController? controller;

  final Set<int> _pointers = <int>{};
  bool _multiTouch = false;
  bool _enabled = true;
  DateTime? _multiTouchEndedAt;

  bool get isEnabled => _enabled;

  /// True while a refresh would be attributable to a multi-touch gesture.
  bool get suppressesRefresh {
    if (_multiTouch) return true;
    final endedAt = _multiTouchEndedAt;
    return endedAt != null && _now().difference(endedAt) < _multiTouchGrace;
  }

  void onPointerDown(int pointer) {
    _pointers.add(pointer);
    if (_pointers.length < 2 || _multiTouch) return;
    _multiTouch = true;
    _setEnabled(false);
  }

  void onPointerUp(int pointer) {
    if (!_pointers.remove(pointer)) return;
    if (_pointers.isNotEmpty || !_multiTouch) return;
    _multiTouch = false;
    _multiTouchEndedAt = _now();
    _setEnabled(true);
  }

  /// Runs [onRefresh] unless the gesture behind it was a pinch, in which
  /// case the spinner is stopped and the page is left alone.
  Future<void> runRefresh(Future<void> Function() onRefresh) async {
    if (suppressesRefresh) {
      await _swallow(_control.endRefreshing);
      return;
    }
    await onRefresh();
  }

  void _setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    unawaited(_swallow(() => _control.setEnabled(enabled)));
  }

  // The control is reachable only once the native view is attached; a pointer
  // arriving before that (or after disposal) must not surface as an error.
  Future<void> _swallow(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {}
  }
}
