import 'package:webspace/web_view_model.dart';

/// The outcome of a navigation-interception decision.
enum NavigationDecision {
  /// Let the navigation proceed in the current webview (same-domain, or
  /// inline/about/captcha special cases that don't count as cross-domain).
  allow,

  /// Cancel the navigation without any UI side-effect — the
  /// `blockAutoRedirects` setting swallowed a script-initiated redirect
  /// that had no user gesture.
  blockSilent,

  /// Cancel the navigation and don't open a nested webview because the
  /// originating site is in the IndexedStack background. Dialogs from
  /// background sites would layer over the active one.
  blockSuppressed,

  /// Cancel the navigation and hand the URL to an `InAppBrowser` nested
  /// webview.
  blockOpenNested,
}

/// How the caller should update its stored `lastSameDomainGestureTime`
/// after applying the decision.
enum GestureStateUpdate {
  /// Set `lastSameDomainGestureTime` to the supplied `now` — the user
  /// just tapped a same-domain link and we want to propagate the gesture
  /// into any server-side redirect that fires within the next 10s.
  record,

  /// Set `lastSameDomainGestureTime` to `null` — a cross-domain request
  /// consumed the recorded gesture (regardless of whether the request
  /// was allowed or blocked). Single-use on purpose: a stale gesture
  /// must not unlock repeated redirects.
  consume,
}

class NavigationDecisionResult {
  final NavigationDecision decision;

  /// When non-null, the caller applies this update to its stored
  /// `lastSameDomainGestureTime` variable. `null` means "leave it alone".
  final GestureStateUpdate? gestureUpdate;

  const NavigationDecisionResult(this.decision, [this.gestureUpdate]);
}

/// State owned by the onUrlChanged call site. Immutable; the engine returns
/// a new `OnUrlChangedState` in its result and the caller swaps it in.
class OnUrlChangedState {
  /// Set to true after the engine has handled a cross-domain redirect
  /// (blockSilent / blockSuppressed / blockOpenNested). Guards against
  /// re-entrant handling from duplicate events (onUrlChanged is called by
  /// both onUpdateVisitedHistory and onLoadStop), and is cleared when a
  /// same-domain URL arrives.
  final bool redirectHandled;

  /// The URL before the most recent same-domain URL change. When a
  /// cross-domain redirect is caught, the engine instructs the caller to
  /// `controller.loadUrl(previousSameDomainUrl ?? initUrl)` so the redirect
  /// target doesn't remain visible in the main webview while the nested
  /// browser opens.
  final String? previousSameDomainUrl;

  /// The URL the webview is currently displaying for the site. Never holds
  /// a cross-domain URL — the engine refuses to commit those so that
  /// `previousSameDomainUrl = currentUrl` on the next same-domain event
  /// can't save a stale cross-domain URL and break the loadUrl-back step
  /// on subsequent redirects.
  final String currentUrl;

  const OnUrlChangedState({
    required this.redirectHandled,
    required this.previousSameDomainUrl,
    required this.currentUrl,
  });

  /// Initial state for a freshly created webview. `currentUrl` starts at
  /// `initUrl`; `previousSameDomainUrl` is null (the first cross-domain
  /// redirect will fall back to `initUrl` in `loadUrl`).
  factory OnUrlChangedState.initial(String initUrl) => OnUrlChangedState(
        redirectHandled: false,
        previousSameDomainUrl: null,
        currentUrl: initUrl,
      );

  OnUrlChangedState copyWith({
    bool? redirectHandled,
    String? previousSameDomainUrl,
    String? currentUrl,
  }) =>
      OnUrlChangedState(
        redirectHandled: redirectHandled ?? this.redirectHandled,
        previousSameDomainUrl: previousSameDomainUrl ?? this.previousSameDomainUrl,
        currentUrl: currentUrl ?? this.currentUrl,
      );
}

/// The actionable outcome of a full onUrlChanged invocation. The caller
/// wires this back into its native / widget world:
///   * if [navigateBackTo] != null → `controller.loadUrl(navigateBackTo)`
///   * if [launchNestedUrl] != null → push an `InAppBrowser` at that URL
///   * swap [state] into the webview's closure-level state
///   * if [gestureUpdate] != null → apply to `lastSameDomainGestureTime`
///   * [decision] is exposed for logging; null means "no decision made
///     (duplicate event swallowed by redirectHandled, or inline scheme)".
class OnUrlChangedHandled {
  final NavigationDecision? decision;
  final String? navigateBackTo;
  final String? launchNestedUrl;
  final OnUrlChangedState state;
  final GestureStateUpdate? gestureUpdate;

  const OnUrlChangedHandled({
    required this.decision,
    required this.navigateBackTo,
    required this.launchNestedUrl,
    required this.state,
    required this.gestureUpdate,
  });
}

/// The gesture-propagation window. A same-domain click sets
/// `lastSameDomainGestureTime`; any cross-domain navigation that fires
/// within this window inherits the gesture (covering search-engine
/// redirect links like DuckDuckGo's `/l/?uddg=...` or Google's
/// `/url?q=...`), then consumes it so a single click can't unlock
/// repeated redirects.
const _gesturePropagationWindowSeconds = 10;

/// Logic for cross-domain navigation interception, extracted from
/// `WebViewModel.getWebView`'s `shouldOverrideUrlLoading` / `onUrlChanged`
/// closures and from the matching inline copy in
/// `test/nested_webview_navigation_test.dart`'s `NavigationTestHarness`
/// (which previously carried a comment saying it "replicates the exact
/// logic from WebViewModel.getWebView"). Both sites now delegate here
/// so the rule can't drift.
///
/// The engine is stateless. Gesture state lives on the caller as a
/// mutable `DateTime?`; the engine reads it as an input and returns an
/// optional update descriptor the caller applies after the call.
class NavigationDecisionEngine {
  /// Decision for `shouldOverrideUrlLoading`. Semantics mirror the
  /// production callback exactly:
  ///
  ///   * `about:blank` / `about:srcdoc` — allowed so Cloudflare Turnstile
  ///     and other captcha iframes can render.
  ///   * `data:` / `blob:` — allowed (inline content, no real domain).
  ///   * same normalized base domain — allowed; records a gesture if
  ///     `hasGesture` is true so any cross-domain redirect within the
  ///     next 10 seconds can inherit it.
  ///   * cross-domain — consumes any pending gesture, then:
  ///       * `blockAutoRedirects && !effectiveGesture` → [blockSilent]
  ///       * `!isSiteActive` → [blockSuppressed]
  ///       * otherwise → [blockOpenNested]
  ///
  /// [isSiteActive] should be `true` when the site has no isActive
  /// callback (the production default).
  static NavigationDecisionResult decideShouldOverrideUrlLoading({
    required String targetUrl,
    required String initUrl,
    required bool hasGesture,
    required bool blockAutoRedirects,
    required bool isSiteActive,
    required DateTime? lastSameDomainGestureTime,
    required DateTime now,
  }) {
    if (targetUrl == 'about:blank' || targetUrl == 'about:srcdoc') {
      return const NavigationDecisionResult(NavigationDecision.allow);
    }
    final scheme = Uri.tryParse(targetUrl)?.scheme ?? '';
    if (scheme == 'data' || scheme == 'blob') {
      return const NavigationDecisionResult(NavigationDecision.allow);
    }

    final targetDomain = getNormalizedDomain(targetUrl);
    final baseDomain = getNormalizedDomain(initUrl);
    if (targetDomain == baseDomain) {
      return NavigationDecisionResult(
        NavigationDecision.allow,
        hasGesture ? GestureStateUpdate.record : null,
      );
    }

    var effectiveGesture = hasGesture;
    GestureStateUpdate? gestureUpdate;
    if (!hasGesture && lastSameDomainGestureTime != null) {
      final elapsed = now.difference(lastSameDomainGestureTime);
      if (elapsed.inSeconds < _gesturePropagationWindowSeconds) {
        effectiveGesture = true;
      }
      gestureUpdate = GestureStateUpdate.consume;
    }

    if (blockAutoRedirects && !effectiveGesture) {
      return NavigationDecisionResult(NavigationDecision.blockSilent, gestureUpdate);
    }
    if (!isSiteActive) {
      return NavigationDecisionResult(NavigationDecision.blockSuppressed, gestureUpdate);
    }
    return NavigationDecisionResult(NavigationDecision.blockOpenNested, gestureUpdate);
  }

  /// Decision for `onUrlChanged` — detects server-side 3xx redirects that
  /// bypassed `shouldOverrideUrlLoading`. Caller interpretation:
  ///
  ///   * [allow] — no-op; URL is same-domain, an inline/about URI, or
  ///     a recognized captcha challenge; update `currentUrl` as normal.
  ///   * [blockSilent] — caller navigates the webview back to the last
  ///     same-domain URL and does nothing else.
  ///   * [blockSuppressed] — caller navigates back; the nested webview
  ///     is not opened because the site is a background IndexedStack
  ///     entry.
  ///   * [blockOpenNested] — caller navigates back and opens the target
  ///     URL in an InAppBrowser nested webview.
  ///
  /// [isCaptchaChallenge] is injected so the engine doesn't duplicate
  /// the captcha domain list from `WebViewFactory`.
  static NavigationDecisionResult decideOnUrlChanged({
    required String newUrl,
    required String initUrl,
    required bool blockAutoRedirects,
    required bool isSiteActive,
    required DateTime? lastSameDomainGestureTime,
    required DateTime now,
    required bool Function(String url) isCaptchaChallenge,
  }) {
    final scheme = Uri.tryParse(newUrl)?.scheme ?? '';
    if (scheme == 'data' || scheme == 'blob' || scheme == 'about') {
      return const NavigationDecisionResult(NavigationDecision.allow);
    }

    final targetDomain = getNormalizedDomain(newUrl);
    final baseDomain = getNormalizedDomain(initUrl);
    if (targetDomain == baseDomain) {
      return const NavigationDecisionResult(NavigationDecision.allow);
    }
    if (isCaptchaChallenge(newUrl)) {
      return const NavigationDecisionResult(NavigationDecision.allow);
    }

    var hasRecentGesture = false;
    GestureStateUpdate? gestureUpdate;
    if (lastSameDomainGestureTime != null) {
      final elapsed = now.difference(lastSameDomainGestureTime);
      if (elapsed.inSeconds < _gesturePropagationWindowSeconds) {
        hasRecentGesture = true;
      }
      gestureUpdate = GestureStateUpdate.consume;
    }

    if (blockAutoRedirects && !hasRecentGesture) {
      return NavigationDecisionResult(NavigationDecision.blockSilent, gestureUpdate);
    }
    if (!isSiteActive) {
      return NavigationDecisionResult(NavigationDecision.blockSuppressed, gestureUpdate);
    }
    return NavigationDecisionResult(NavigationDecision.blockOpenNested, gestureUpdate);
  }

  /// Full onUrlChanged flow: runs [decideOnUrlChanged] against the caller's
  /// current state, then returns an [OnUrlChangedHandled] describing the
  /// side effects to perform and the new state to store.
  ///
  /// State invariants maintained here:
  ///   * When a cross-domain redirect is caught, `redirectHandled` is set
  ///     so the duplicate event fired by the other of onLoadStop /
  ///     onUpdateVisitedHistory can't re-trigger the decision logic.
  ///   * `currentUrl` only advances on same-domain / inline URLs. Committing
  ///     a cross-domain URL here would poison the next same-domain event's
  ///     `previousSameDomainUrl = currentUrl` step, which would then cause
  ///     the next cross-domain redirect's loadUrl-back to navigate into the
  ///     cross-domain URL (which the CANCEL path kills) — the symptom the
  ///     user sees is "nth attempt doesn't open a nested browser."
  ///   * `previousSameDomainUrl = currentUrl` runs on a same-domain arrival
  ///     *before* `currentUrl` is updated to the new URL, so it captures
  ///     the prior same-domain URL the user was viewing.
  static OnUrlChangedHandled handleOnUrlChanged({
    required String newUrl,
    required String initUrl,
    required bool blockAutoRedirects,
    required bool isSiteActive,
    required DateTime? lastSameDomainGestureTime,
    required DateTime now,
    required bool Function(String url) isCaptchaChallenge,
    required OnUrlChangedState state,
  }) {
    final initDomain = getNormalizedDomain(initUrl);
    final urlDomain = getNormalizedDomain(newUrl);

    if (!state.redirectHandled) {
      final result = decideOnUrlChanged(
        newUrl: newUrl,
        initUrl: initUrl,
        blockAutoRedirects: blockAutoRedirects,
        isSiteActive: isSiteActive,
        lastSameDomainGestureTime: lastSameDomainGestureTime,
        now: now,
        isCaptchaChallenge: isCaptchaChallenge,
      );
      if (result.decision != NavigationDecision.allow) {
        final navigateBackTo = state.previousSameDomainUrl ?? initUrl;
        final launchNestedUrl =
            result.decision == NavigationDecision.blockOpenNested ? newUrl : null;
        return OnUrlChangedHandled(
          decision: result.decision,
          navigateBackTo: navigateBackTo,
          launchNestedUrl: launchNestedUrl,
          state: state.copyWith(redirectHandled: true),
          gestureUpdate: result.gestureUpdate,
        );
      }
      // decision == allow; fall through to the commit path below.
    }

    // Cross-domain URL arriving after a handled redirect — typically the
    // duplicate event from the other of onLoadStop/onUpdateVisitedHistory.
    // Don't pollute currentUrl / previousSameDomainUrl with it.
    if (state.redirectHandled && urlDomain != initDomain) {
      return OnUrlChangedHandled(
        decision: null,
        navigateBackTo: null,
        launchNestedUrl: null,
        state: state,
        gestureUpdate: null,
      );
    }

    // Inline schemes (data:, blob:, about:) aren't real pages.
    // decideOnUrlChanged returns `allow` for them so the caller knows
    // not to block — but committing them as currentUrl would later
    // poison previousSameDomainUrl when a same-domain URL arrives
    // (`previousSameDomainUrl = state.currentUrl` would save the inline
    // URL). The next cross-domain redirect's loadUrl-back would then
    // navigate the parent webview to about:blank / data: / blob:
    // instead of a real prior page, leaving the user staring at a
    // blank screen.
    //
    // about:blank specifically fires for captcha iframes, intermediate
    // chromium navigation states, and as the placeholder URL during
    // page tear-down — none of which represent a navigation we want
    // to track.
    final newScheme = Uri.tryParse(newUrl)?.scheme ?? '';
    if (newScheme == 'data' || newScheme == 'blob' || newScheme == 'about') {
      return OnUrlChangedHandled(
        decision: null,
        navigateBackTo: null,
        launchNestedUrl: null,
        state: state,
        gestureUpdate: null,
      );
    }

    var nextState = state;
    if (urlDomain == initDomain) {
      // Only advance previousSameDomainUrl when the URL actually
      // changed. Duplicate onUrlChanged events (onLoadStop +
      // onUpdateVisitedHistory both fire for the same URL) would
      // otherwise overwrite previousSameDomainUrl with the URL the
      // webview is already on, losing the genuine prior page reference.
      //
      // Concrete failure when this guard is missing: user taps an
      // outbound link wrapped in a same-domain redirector (e.g.
      // linkedin.com/safety/go?url=reddit). The redirector URL fires
      // onUrlChanged twice; the second event sets previousSameDomainUrl
      // to the redirector itself. The server-side 302 to the
      // cross-domain target then fires onUrlChanged(target); the
      // navigate-back uses state.previousSameDomainUrl as its target,
      // which is the redirector, which 302s back to the cross-domain,
      // which fires onUrlChanged again — infinite loop until chromium
      // exhausts iframe lifecycle bookkeeping and trips a
      // dangling-raw_ptr on Chrome_IOThread.
      nextState = nextState.copyWith(
        redirectHandled: false,
        previousSameDomainUrl: newUrl != state.currentUrl
            ? state.currentUrl
            : state.previousSameDomainUrl,
      );
    }
    nextState = nextState.copyWith(currentUrl: newUrl);
    return OnUrlChangedHandled(
      decision: null,
      navigateBackTo: null,
      launchNestedUrl: null,
      state: nextState,
      gestureUpdate: null,
    );
  }
}
