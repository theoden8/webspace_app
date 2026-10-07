import 'dart:async';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/repaint_log_throttle.dart';
import 'package:webspace/services/repaint_suppression.dart';
import 'package:webspace/services/surface_repaint_engine.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart'
    show WebViewModel, rendererProbeIndicatesGone;

/// The screen whose webview surface is repainted.
abstract interface class SurfaceHost {
  bool get mounted;

  /// [SurfaceRepaintController.bottomInset] or [SurfaceRepaintController.hidden]
  /// changed.
  void rebuild();
}

/// The manual repaint's mechanisms, one per successive tap (PAUSE-028).
enum ManualRepaint {
  inset1('inset-1'),
  inset16('inset-16'),
  unpaint('unpaint'),
  nativeInvalidate('native-invalidate'),
  nativeVisibility('native-visibility'),
  recreate('recreate');

  const ManualRepaint(this.label);

  final String label;
}

/// Repaints an Android hybrid-composition webview surface that came back
/// without a paint (BUG-001): the main page's and every nested screen's.
///
/// After the activity is recreated (a shortcut tap, a resume), a back/forward
/// restore, a reload or a route pop, the Flutter surface and the webview
/// SurfaceView can come back blank although the page is alive. A relayout
/// fixes it, which is what rotation, lock-unlock and a tab switch do, so
/// [nudge] toggles a small inset under the webview a few times over ~0.5s:
/// each flip recomposites the platform view. Spread across frames because the
/// new surface may not be attached on the first one. [SurfaceRepaintEngine]
/// decides the ticks; this owns the clock and the trace. Off Android nothing
/// runs.
class SurfaceRepaintController {
  SurfaceRepaintController(
    this._host, {
    required this.repaints,
    required this.traceSuffix,
  });

  final SurfaceHost _host;

  /// Whether this surface needs the loop: Android's hybrid composition.
  final bool repaints;

  /// Appended to every trigger in the trace, so two surfaces' lines differ.
  final String traceSuffix;

  final SurfaceRepaintEngine _engine = SurfaceRepaintEngine();
  bool _nudged = false;

  // The inset provably does not repaint the surface on the reporting device
  // (BUG-001 gap #18) while rotation, lock-unlock and a tab switch do; the
  // manual repaint cycles through mechanisms so a device can say which
  // property matters. Steady state is 1px and painted.
  double _insetPx = 1.0;
  bool _hidden = false;
  int _manualPass = 0;

  Timer? _commitWindowTimer;
  final RepaintLogThrottle _log = RepaintLogThrottle();
  Timer? _logFlushTimer;
  bool _resumeWindowOpen = false;
  Timer? _resumeWindowTimer;

  /// The inset under the webview now; zero in steady state.
  double get bottomInset => _nudged ? _insetPx : 0.0;

  /// The webview subtree is held unpainted for a frame (PAUSE-028).
  bool get hidden => _hidden;

  /// Runs the repaint loop for [trigger], or extends the one running:
  /// concurrent callers coalesce onto one loop so two cannot toggle the inset
  /// against each other, and the engine settles it at a zero inset.
  void nudge(String trigger) {
    if (!repaints) return;
    // Debug-only, diag tiers only: drop this trigger so a scenario can observe
    // what the native layer repaints on its own (BUG-001 gap #5). Logged
    // directly, not through the developer-mode trace: the adb probe needs the
    // line in logcat to prove the dropped nudge was reached at all.
    if (RepaintSuppression.suppresses(trigger)) {
      LogTag.surfaceDiag.debug('trigger=$trigger$traceSuffix suppressed');
      return;
    }
    final started = _engine.request();
    _trace(trigger, coalesced: !started);
    if (!started) return;
    void tick() {
      if (!_host.mounted) {
        _engine.abort();
        return;
      }
      final t = _engine.tick();
      _nudged = t.inset;
      _host.rebuild();
      if (t.done) return;
      Future.delayed(const Duration(milliseconds: 100), tick);
    }

    tick();
  }

  /// One repaint on the shareable `SurfaceDiag` trace, from inside the funnel
  /// so every path names itself (hand-written lines at a few call sites left
  /// most paths dark). Only while developer mode is on (DEVTOOLS-010), and
  /// bursts collapse: `didChangeMetrics` fires the same trigger many times a
  /// second. No site name or URL, so the whole trace is shareable.
  void _trace(String trigger, {required bool coalesced}) {
    if (!DeveloperModeService.instance.enabled) return;
    for (final line in _log.note('$trigger$traceSuffix',
        coalesced: coalesced, now: DateTime.now())) {
      LogTag.surfaceDiag.debug(line);
    }
    _logFlushTimer?.cancel();
    if (!_log.hasPending) return;
    _logFlushTimer = Timer(RepaintLogThrottle.burstWindow, () {
      _logFlushTimer = null;
      final summary = _log.flush();
      if (summary != null) LogTag.surfaceDiag.debug(summary);
    });
  }

  /// Arms the commit latch and holds it open for a bounded window, so every
  /// load settling inside it repaints (PAUSE-027): a refresh issued while
  /// another is in flight settles twice and a redirect chain commits an
  /// interstitial first, and a one-shot latch spent on the first settle left
  /// the document on screen blank. The window bounds how long an unrelated
  /// navigation can inherit one.
  void armCommitLatch() {
    _engine.noteCommitPending();
    _commitWindowTimer?.cancel();
    _commitWindowTimer = Timer(SurfaceRepaintEngine.commitWindow, () {
      _commitWindowTimer = null;
      _engine.closeCommitWindow();
    });
  }

  /// A load settled: repaints the recommitted document while the latch is
  /// open (PAUSE-021, PAUSE-025).
  void loadSettled() {
    if (_engine.noteLoadSettled()) nudge('commit-settled');
  }

  /// Repaints [site]'s surface on the events that blank it, while [onScreen]
  /// says it is the one showing; read when the event fires.
  void watch(WebViewModel site, {required bool Function() onScreen}) {
    // A newly mounted hybrid-composition SurfaceView (cold start, go home, a
    // renderer-gone rebuild) can come back blank-white. The nudge covers a
    // surface whose first document has committed; a fresh webview's first
    // load can commit after the nudge's ~0.6s budget, so the commit is
    // latched too (PAUSE-025).
    site.onControllerReady = () {
      if (!onScreen()) return;
      armCommitLatch();
      nudge('controller-attach');
    };
    // A reload blanks the surface between discarding the old frame and
    // committing the new one, and nothing relayouts it in between
    // (PAUSE-021): nudge for a fast recommit, latch for a late one.
    site.onReloadIssued = () {
      if (!onScreen()) return;
      armCommitLatch();
      nudge('reload');
    };
    // Not gated on the commit window: BUG-001 gap #18 caught a renderer
    // producing its first content well after the window closed.
    site.onPageCommitVisible = () {
      if (onScreen()) nudge('page-commit-visible');
    };
    site.onLoadSettled = () {
      if (onScreen()) loadSettled();
    };
  }

  /// Opens the post-resume window (PAUSE-020): a SurfaceView can re-attach a
  /// frame or more after `resumed`, later than the resume's own nudge, and the
  /// re-attach reaches Dart as a metrics change. Bounded so steady-state
  /// metric changes (keyboard, rotation) don't nudge.
  void openResumeWindow() {
    if (!repaints) return;
    _resumeWindowOpen = true;
    _resumeWindowTimer?.cancel();
    _resumeWindowTimer = Timer(const Duration(seconds: 3), () {
      _resumeWindowOpen = false;
      _resumeWindowTimer = null;
    });
  }

  /// `didChangeMetrics`: inside the post-resume window it is the closest
  /// Dart-side signal to the surface re-attaching.
  void metricsChanged() {
    if (_resumeWindowOpen) nudge('metrics-resume');
  }

  /// The mechanism the next manual repaint tries (PAUSE-028), each tap a
  /// different one: BUG-001 gap #18 caught six nudges against a live renderer
  /// with the screen blank, while rotation, lock-unlock and a tab switch
  /// recover it. They differ from a 1px resize in magnitude, in whether the
  /// view stops being painted, and in whether the platform view is destroyed.
  /// The chosen magnitude sticks for later nudges in the session.
  ManualRepaint nextManual() {
    const mechanisms = ManualRepaint.values;
    final mechanism = mechanisms[_manualPass % mechanisms.length];
    _manualPass++;
    LogTag.surfaceDiag.debug('manual mechanism=${mechanism.label}');
    _insetPx = mechanism == ManualRepaint.inset16 ? 16.0 : 1.0;
    return mechanism;
  }

  /// Holds the subtree unpainted for a few frames, mounted and laid out.
  /// Flutter drops the platform view's layer while nothing paints it, so the
  /// Android view leaves and re-enters the hierarchy without the WebView
  /// being destroyed: what a tab switch does and a resize does not.
  Future<void> holdUnpainted() async {
    if (_hidden) return;
    _hidden = true;
    _host.rebuild();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!_host.mounted) return;
    _hidden = false;
    _host.rebuild();
  }

  /// Whether [controller]'s renderer is gone, read off a synchronous layout
  /// (PAUSE-013, PAUSE-019). Covers what returning to a backgrounded webview
  /// meets: on iOS a content process jettisoned while offscreen, whose
  /// termination delegate does not reliably fire, answers the call with
  /// nothing; on Android a live renderer whose surface re-attached blank
  /// answers with a number, and the layout the read forces schedules the
  /// missing paint. Only a null answer is gone.
  ///
  /// Never true for a suppressed [trigger]: the read is a repaint path
  /// itself, so a diag scenario isolating the native layer drops it too.
  Future<bool> rendererGone(
    WebViewController controller, {
    required String trigger,
    required String siteId,
  }) async {
    if (RepaintSuppression.suppresses(trigger)) {
      LogTag.surfaceDiag.debug('trigger=$trigger probe suppressed');
      return false;
    }
    final result = await controller.evaluateJavascriptReturning(
        'document.body ? document.body.offsetHeight : -1');
    if (!_host.mounted) return false;
    final gone = rendererProbeIndicatesGone(result);
    // No site name or URL: separates a dead renderer (null, BUG-002,
    // recreate) from a live unpainted surface (a number, BUG-001, nudge).
    LogTag.surfaceDiag.debug(
        'trigger=$trigger$traceSuffix site=$siteId probe=${result ?? 'null'} → '
        '${gone ? 'renderer-gone (recreate)' : 'renderer-alive (nudge)'}');
    // -1 is `document.body` missing, which counts as alive: the renderer
    // answered. A surface nudge cannot repaint a document with no body, so
    // say which document answered and where its body went (BUG-001 gap #17).
    if (!gone && result.toString() == '-1') {
      final detail = await controller.evaluateJavascriptReturning(
          "(function(){var r=document.documentElement,"
          "b=document.getElementsByTagName('body');"
          "return document.readyState+' root='+(r?r.nodeName:'none')"
          "+' roots='+document.children.length+' bodies='+b.length"
          "+' bodyParent='+(b[0]&&b[0].parentNode?b[0].parentNode.nodeName:'-')"
          "+' '+location.protocol+'//'+location.host;})()");
      if (!_host.mounted) return false;
      LogTag.surfaceDiag.debug(
          'trigger=$trigger$traceSuffix site=$siteId no body: ${detail ?? 'null'}');
    }
    return gone;
  }

  void dispose() {
    _commitWindowTimer?.cancel();
    _logFlushTimer?.cancel();
    _resumeWindowTimer?.cancel();
  }
}
