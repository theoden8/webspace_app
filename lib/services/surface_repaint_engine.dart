/// Pure-Dart model of the Android surface-repaint nudge (PAUSE-015/017/018),
/// the runtime counterpart of `formal/kernel.tla`'s repaint machine. It owns
/// two decisions and no side effects: (1) which transitions re-attach the
/// visible hybrid-composition SurfaceView and therefore owe a repaint, and
/// (2) the coalescing tick loop that drives `_nudgeSurfaceRepaint`. The host
/// supplies the clock (`Future.delayed`) and the side effect (`setState` of the
/// 1px inset); this class never imports Flutter, so it is unit- and
/// interleaving-testable. See test/surface_repaint_engine_test.dart.
library;

/// Surface lifecycle transitions on the visible site. Every value except
/// [appBackground] (re)attaches the SurfaceView and must be followed by a
/// repaint nudge — that is the coverage contract behind BUG-001. A new
/// surface-attach path MUST be added here and routed through the host nudge.
enum SurfaceTransition {
  activate, // _setCurrentIndex (PAUSE-015)
  resume, // _onResumed (PAUSE-015)
  controllerAttach, // fresh controller mounts a new SurfaceView (PAUSE-017)
  back, // bfcache restore reuses the controller (PAUSE-018)
  forward, // bfcache restore reuses the controller (PAUSE-018)
  goHome, // dispose + rebuild at initUrl (PAUSE-017)
  rendererRebuilt, // renderer-gone recovery rebuild (PAUSE-017)
  appBackground, // app going to background: no attach, no repaint owed
}

/// The action the host applies for one tick: render [inset] (the 1px inset
/// state) via setState, then schedule the next tick unless [done].
class RepaintTick {
  final bool inset;
  final bool done;
  const RepaintTick({required this.inset, required this.done});
}

class SurfaceRepaintEngine {
  /// Number of inset toggles per request. Spread across frames because a
  /// freshly-attached surface may not be composited on the first frame.
  static const int ticksPerRequest = 6;

  int _ticksRemaining = 0;
  bool _looping = false;
  bool _inset = false;

  /// Current 1px-inset state to render.
  bool get inset => _inset;

  /// Whether a tick loop is currently running.
  bool get isLooping => _looping;

  /// True iff [t] re-attaches the visible surface and so must be followed by a
  /// repaint. The complete set is the contract; mirrors `Attach` in kernel.tla.
  static bool mustRepaint(SurfaceTransition t) =>
      t != SurfaceTransition.appBackground;

  /// Request a nudge. Refills the tick budget and returns whether the host
  /// should START the tick loop (true), or an already-running loop absorbed
  /// the request (false). Coalescing: concurrent callers never start two loops
  /// that would toggle the inset against each other.
  bool request() {
    _ticksRemaining = ticksPerRequest;
    if (_looping) return false;
    _looping = true;
    return true;
  }

  /// Advance one tick. Toggles the inset until the budget drains, then settles
  /// at a zero inset (an odd refill mid-loop could otherwise strand the 1px
  /// inset, leaving a thin sliver between the webview and the tab strip).
  RepaintTick tick() {
    if (_ticksRemaining <= 0) {
      _looping = false;
      _inset = false;
      return const RepaintTick(inset: false, done: true);
    }
    _ticksRemaining--;
    _inset = !_inset;
    return RepaintTick(inset: _inset, done: false);
  }

  /// Abort the loop with no further ticks (host unmounted mid-loop). The widget
  /// is gone, so there is no inset to settle on screen.
  void abort() {
    _ticksRemaining = 0;
    _looping = false;
    _inset = false;
  }
}
