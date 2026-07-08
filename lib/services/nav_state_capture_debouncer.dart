import 'dart:async';

/// Per-site trailing-edge debounce for navigation-driven
/// `controller.saveState()` captures (PAUSE-009).
///
/// SPA pseudo-navigations can fire many URL-change events per page
/// (8+ observed on LinkedIn); `saveState()` is a cross-IPC into
/// chromium returning up to tens of KB, plus an AES encrypt and a disk
/// write. A trailing debounce coalesces a navigation burst into one
/// capture after it settles, while still guaranteeing the *last*
/// navigation before an OS kill lands on disk — which a leading-edge
/// throttle (the `HtmlCacheService.shouldSave` shape) would drop.
class NavStateCaptureDebouncer {
  NavStateCaptureDebouncer({this.delay = const Duration(seconds: 3)});

  final Duration delay;
  final Map<String, Timer> _timers = {};

  /// (Re)start the debounce window for [siteId]. [capture] runs once
  /// [delay] elapses with no further [schedule] call for the same site.
  /// The callback must do its own liveness checks (site deleted,
  /// widget unmounted) — the debouncer only owns the timing.
  void schedule(String siteId, void Function() capture) {
    _timers[siteId]?.cancel();
    _timers[siteId] = Timer(delay, () {
      _timers.remove(siteId);
      capture();
    });
  }

  /// Drop any pending capture for [siteId] without running it.
  void cancel(String siteId) {
    _timers.remove(siteId)?.cancel();
  }

  /// Cancel every pending capture. Call from the host's `dispose()`.
  void dispose() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }
}
