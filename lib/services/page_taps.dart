import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/log_service.dart';

/// Which touches on a webview are taps (NESTED-017), for the platform whose
/// webview reports no gesture for a navigation a page's script starts:
/// WebKit's public API gives only a navigation's type, and a button that
/// navigates from script reports `other`, as a page moving on its own does.
///
/// Fed from Flutter's own pointer stream, which a page cannot write to. A tap
/// is one pointer, primary button, let go within the hit slop and before a
/// long press, so a scroll, a pinch or a long press is none.
class PageTaps {
  PageTaps({required this.onTap});

  /// iOS, the one platform whose pointer stream over a webview the app reads
  /// already (NAV-006) and whose webview reports no such gesture.
  static bool get offered => hostIsIOS;

  /// Whether a tap counts as a gesture now: offered here and the tap gestures
  /// experiment on (DEVTOOLS-011).
  static bool get countAsGestures =>
      offered &&
      ExperimentalFeaturesService.instance
          .isEnabled(ExperimentalFeature.tapGestures);

  /// [webView] with its raw pointer stream fed to a [PageTaps] for
  /// [onPageTap], where taps are offered. A [Listener] never joins the gesture
  /// arena, so the webview keeps every touch. The experiment is read at each
  /// tap, so its switch takes effect without rebuilding the view.
  static Widget around(Widget webView, {required void Function()? onPageTap}) {
    if (onPageTap == null || !offered) return webView;
    final taps = PageTaps(onTap: () {
      if (!countAsGestures) return;
      LogTag.webView.debug('tap on the page: a gesture for the next hop');
      onPageTap();
    });
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: taps.down,
      onPointerMove: taps.move,
      onPointerUp: taps.up,
      onPointerCancel: taps.cancel,
      child: webView,
    );
  }

  final void Function() onTap;

  int? _pointer;
  Offset _origin = Offset.zero;
  Duration _downAt = Duration.zero;
  double _slop = kTouchSlop;
  bool _spoiled = false;

  void down(PointerDownEvent event) {
    if (_pointer != null) {
      _spoiled = true;
      return;
    }
    _pointer = event.pointer;
    _origin = event.position;
    _downAt = event.timeStamp;
    _slop = computeHitSlop(event.kind, null);
    _spoiled = event.buttons != kPrimaryButton;
  }

  void move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.position - _origin).distance > _slop) _spoiled = true;
  }

  void up(PointerUpEvent event) {
    if (event.pointer != _pointer) return;
    final tap = !_spoiled &&
        (event.position - _origin).distance <= _slop &&
        event.timeStamp - _downAt < kLongPressTimeout;
    _pointer = null;
    if (tap) onTap();
  }

  void cancel(PointerCancelEvent event) {
    if (event.pointer == _pointer) _pointer = null;
  }
}
