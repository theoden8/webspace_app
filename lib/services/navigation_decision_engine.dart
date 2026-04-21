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
}
