/// Pure-Dart decision engine for PAUSE-022: a main-frame load that never
/// finished because the app was in the background.
///
/// Distinct from the blank-surface class (BUG-001 / `SurfaceRepaintEngine`):
/// there the document is committed and painted-over-nothing, here there is no
/// committed document at all — the OS (or a per-app background network policy
/// such as CalyxOS/Datura, or Android's own background restrictions) cut the
/// connection out from under an in-flight navigation, so the user comes back
/// to a browser error page or to a page that never appears. A repaint nudge
/// cannot fix that; only re-issuing the load can.
///
/// The engine owns the state machine and the decision; the host owns the
/// clock, the connectivity probe and the controller call. It never imports
/// Flutter, so it unit-tests without a widget. See
/// test/resume_reload_engine_test.dart.
library;

/// Where a main-frame navigation is in its lifecycle, as reported by the
/// webview factory (`onLoadStart` / `onLoadStop` / `onReceivedError`).
enum MainFrameLoadPhase { started, settled, failed }

/// One main-frame load lifecycle event. [url] is the navigation target
/// ([MainFrameLoadPhase.settled] carries none); [errorType] is the platform
/// `WebResourceErrorType.toValue()` string and is set only for
/// [MainFrameLoadPhase.failed].
class MainFrameLoadSignal {
  final MainFrameLoadPhase phase;
  final String? url;
  final String? errorType;

  const MainFrameLoadSignal.started(String this.url)
      : phase = MainFrameLoadPhase.started,
        errorType = null;

  const MainFrameLoadSignal.settled()
      : phase = MainFrameLoadPhase.settled,
        url = null,
        errorType = null;

  const MainFrameLoadSignal.failed(String this.url, String this.errorType)
      : phase = MainFrameLoadPhase.failed;
}

/// What the host should do next for this webview.
enum ResumeRetryAction {
  /// Nothing to recover.
  none,

  /// Re-issue [ResumeRetryPlan.url] now (subject to the host's connectivity
  /// gate).
  retryNow,

  /// A navigation was still in flight when the app was backgrounded and still
  /// is. Wait [ResumeRetryPlan.delay] and ask again: a load that was merely
  /// slow finishes on its own and needs no retry, while one whose socket the
  /// OS dropped stays stuck and comes back as [retryNow].
  waitAndReplan,
}

class ResumeRetryPlan {
  final ResumeRetryAction action;

  /// URL to re-issue. Non-null exactly when [action] is
  /// [ResumeRetryAction.retryNow].
  final String? url;

  /// How long to wait before re-planning. Meaningful only for
  /// [ResumeRetryAction.waitAndReplan].
  final Duration delay;

  const ResumeRetryPlan.none()
      : action = ResumeRetryAction.none,
        url = null,
        delay = Duration.zero;

  const ResumeRetryPlan.retryNow(String this.url)
      : action = ResumeRetryAction.retryNow,
        delay = Duration.zero;

  const ResumeRetryPlan.waitAndReplan(this.delay)
      : action = ResumeRetryAction.waitAndReplan,
        url = null;
}

/// Per-webview recovery state. One instance per `WebViewModel` (and one per
/// nested `InAppWebViewScreen`).
class ResumeReloadEngine {
  /// Main-frame failures worth re-issuing once the app is foreground again:
  /// everything whose cause can plausibly be "the network was not reachable
  /// from a backgrounded process". Deliberately excludes failures a retry
  /// cannot change (bad URL, unsupported scheme, file not found), failures a
  /// retry makes worse (redirect loops, rate limiting), and everything the TLS
  /// path in `webview.dart` already owns (certificate + handshake errors) —
  /// silently re-issuing those would paper over a prompt the user must see.
  ///
  /// `UNKNOWN` is included because Android maps several chromium `net::`
  /// connectivity errors onto `ERROR_UNKNOWN` (-1) rather than a specific
  /// code, and it is the code a firewall-dropped connection most often
  /// surfaces as.
  static const Set<String> retryableErrorTypes = {
    'HOST_LOOKUP',
    'CANNOT_CONNECT_TO_HOST',
    'CANNOT_LOAD_FROM_NETWORK',
    'CONNECTION_ABORTED',
    'DATA_NOT_ALLOWED',
    'IO',
    'NETWORK_CONNECTION_LOST',
    'NOT_CONNECTED_TO_INTERNET',
    'RESET',
    'SERVER_UNREACHABLE',
    'TIMEOUT',
    'UNKNOWN',
  };

  /// Re-issues allowed per foreground session. The budget refills on
  /// [noteAppBackgrounded] (every return to the app is a fresh chance —
  /// the user may have just fixed connectivity) and on a load that settles
  /// without an error.
  static const int maxAttempts = 2;

  /// How long to let a navigation that was already in flight at background
  /// time keep running after the resume before treating it as stuck.
  static const Duration stallGrace = Duration(seconds: 2);

  /// How long to let a re-issued load run before planning the next attempt.
  static const Duration retryBackoff = Duration(seconds: 3);

  static bool isRetryable(String errorType) =>
      retryableErrorTypes.contains(errorType);

  bool _inFlight = false;
  String? _inFlightUrl;
  String? _failedUrl;
  bool _backgroundedWhileLoading = false;
  bool _stallGraceSpent = false;
  int _attempts = 0;

  /// Whether a main-frame navigation is currently running.
  bool get isLoading => _inFlight;

  /// URL of the last main-frame load that failed retryably and has not been
  /// re-issued yet, or null.
  String? get failedUrl => _failedUrl;

  int get attempts => _attempts;

  void noteLoad(MainFrameLoadSignal signal) {
    switch (signal.phase) {
      case MainFrameLoadPhase.started:
        _inFlight = true;
        _inFlightUrl = signal.url;
        // A new navigation supersedes the previous failure — including the
        // one a retry is currently re-issuing.
        _failedUrl = null;
      case MainFrameLoadPhase.settled:
        _inFlight = false;
        // `onReceivedError` precedes `onLoadStop` for the same navigation, so
        // a recorded failure survives the settle that reports the error page.
        if (_failedUrl == null) {
          _attempts = 0;
          _backgroundedWhileLoading = false;
          _stallGraceSpent = false;
        }
      case MainFrameLoadPhase.failed:
        _failedUrl = isRetryable(signal.errorType!) ? signal.url : null;
    }
  }

  /// The app went to the background. Records whether a navigation was caught
  /// mid-flight (the case the OS is about to strand) and refills the budget.
  void noteAppBackgrounded() {
    _backgroundedWhileLoading = _inFlight;
    _stallGraceSpent = false;
    _attempts = 0;
  }

  /// The host waited [stallGrace] after the resume and the load is still
  /// stuck, so the next plan escalates from "wait" to "re-issue".
  void noteStallGraceElapsed() {
    _stallGraceSpent = true;
  }

  ResumeRetryPlan planRetry() {
    if (_attempts >= maxAttempts) return const ResumeRetryPlan.none();
    final failed = _failedUrl;
    if (failed != null) return ResumeRetryPlan.retryNow(failed);
    if (_backgroundedWhileLoading && _inFlight) {
      if (!_stallGraceSpent) return const ResumeRetryPlan.waitAndReplan(stallGrace);
      final pending = _inFlightUrl;
      if (pending != null) return ResumeRetryPlan.retryNow(pending);
    }
    return const ResumeRetryPlan.none();
  }

  /// The host issued the re-load from [planRetry]. Spends one attempt and
  /// clears the triggering condition, so an unchanged state cannot re-fire.
  void noteRetryIssued() {
    _attempts++;
    _failedUrl = null;
    _backgroundedWhileLoading = false;
    _stallGraceSpent = false;
  }

  /// Drop all recovery state (fresh controller, site recreated).
  void reset() {
    _inFlight = false;
    _inFlightUrl = null;
    _failedUrl = null;
    _backgroundedWhileLoading = false;
    _stallGraceSpent = false;
    _attempts = 0;
  }
}
