# iOS Universal Link Bypass Specification

## Status

- **Date**: 2026-04-28
- **Status**: Implemented
- **Scope**: iOS only (no-op on Android, macOS, Linux)

## Purpose

Keep webview navigations inside WebSpace's webview on iOS instead of letting WKWebView auto-route them to native apps via apple-app-site-association (Universal Links).

## Problem Statement

`WKWebView` honors apple-app-site-association (AASA) entries: when the user taps a link (or follows a redirect chain rooted in a tap) whose URL matches an installed app's AASA file, iOS routes the navigation **out of the webview into the native app** — silently, without a prompt, and even when the user explicitly added the site to WebSpace and is using the webview on purpose.

User-reported case: open the saved Google Maps site in WebSpace; the redirect chain `https://maps.google.com/` → `https://www.google.com/maps` → `consent.google.com/m` → (user accepts cookies) → `consent.google.com/save` → `https://www.google.com/maps` triggers the native Google Maps app launch on the final hop. The user is forcibly ejected from the webview.

### Why a "detect AASA matches" approach is impossible

iOS exposes no public API to ask "does this URL match an installed app's AASA file?". `UIApplication.canOpenURL(_:)` returns true for any HTTPS URL (Safari handles all of them) and so is useless as a discriminator. AASA contents are published per-domain by app developers and cached opaquely by the OS. There is no enumeration, no lookup, no notification.

A curated list of "known offenders" would be brittle and incomplete — every new app with AASA support would need a manual entry, and the list would silently drift out of date.

### Why a "try the navigation, then react" approach doesn't work

Universal Link routing happens **after** `decidePolicyForNavigationAction:decisionHandler:` returns `.allow` and **before** any onLoadStart / onLoadStop callback fires. By the time we'd notice the app got backgrounded, iOS has already opened the native app and the user is gone.

---

## Solution

Generic prophylactic bypass: on iOS, treat **every gesture-rooted main-frame http(s) navigation** as at-risk. Cancel the navigation, then reissue the same URL via `controller.loadUrl`. WebKit treats programmatic loads as navigation type `.other` and **does not match them against AASA**, so the URL renders inside the webview regardless of which apps are installed.

Pure programmatic navigations (initial nav from `initialUrlRequest`, server redirects without a tap origin, pushState SPA navs) carry no user gesture and don't activate AASA in the first place. Those are passed through without interception, so the bypass adds no overhead to the common case.

A per-URL memo (2 s window) prevents the reissued navigation from looping back into the bypass: the second time the same URL hits `shouldOverrideUrlLoading`, the memo flips it to ALLOW and consumes the entry. A subsequent fresh navigation to the same URL re-engages the bypass.

### Trade-off accepted

The bypass eliminates iOS's "tap a Google Maps link → open Google Maps app" affordance for content rendered in WebSpace. Users who want the native app can still:

- Long-press the link in iOS for the system context menu, then "Open in [App]".
- Use the WebSpace settings → external app launcher (out of scope for this spec).
- Switch to Safari and tap the link there.

This is consistent with WebSpace's overall posture (webview-first, opt-in external launches via the existing `ExternalUrlParser` flow for `intent://` / `tel:` / `mailto:` / etc.).

---

## Requirements

### Requirement: IOS-UL-001 - Cancel-and-Reissue Gesture-Rooted Navigations

The system SHALL cancel main-frame http(s) navigations whose `WKNavigationAction.navigationType` is `.linkActivated` or `.formSubmitted` and reissue the same URL via `controller.loadUrl` with the original headers preserved.

#### Scenario: User taps a link to a URL that matches an installed app's AASA

**Given** the device has a UL-capable native app installed (e.g. Google Maps)
**And** the user is viewing a WebSpace site in the webview
**When** the user taps a link to a URL whose host has an AASA entry for the installed app
**Then** the navigation is cancelled
**And** the URL is reissued via `controller.loadUrl`
**And** the page renders inside the webview
**And** the native app does NOT open

#### Scenario: Server redirect after form POST inherits the gesture

**Given** the user submits a form that 302-redirects to a UL-matching URL
**When** WebKit reports the redirect navigation with `navigationType == .formSubmitted`
**Then** the redirect URL is also cancelled and reissued
**And** the page renders inside the webview

---

### Requirement: IOS-UL-002 - Pass Through Programmatic Navigations

The system SHALL NOT intercept navigations whose `navigationType` is `.other`, `.backForward`, `.reload`, or anything other than `.linkActivated` / `.formSubmitted`.

#### Scenario: Initial site load

**Given** WebSpace creates a webview with `initialUrlRequest = URLRequest(url: maps.google.com)`
**When** WKWebView fires `decidePolicyForNavigationAction` with `navigationType == .other`
**Then** the bypass does NOT fire (no extra IPC round-trip)
**And** the page loads normally
**And** AASA does not activate (programmatic loads don't match against AASA)

#### Scenario: Server redirect without a user-tap origin

**Given** a page server-redirects via 302 with no preceding click
**When** the redirect navigation has `navigationType == .other`
**Then** the bypass does NOT fire
**And** the URL loads normally

---

### Requirement: IOS-UL-003 - Anti-Loop Memo

The system SHALL maintain a per-WebView memo of URLs just cancelled-and-reissued so the reissued navigation passes through `shouldOverrideUrlLoading` without looping back into the bypass.

#### Scenario: Reissued navigation lands in shouldOverrideUrlLoading

**Given** the bypass just cancelled URL `X` and called `controller.loadUrl(X)`
**When** WKWebView fires `shouldOverrideUrlLoading` for the reissued navigation
**Then** the memo entry for `X` flips the decision to ALLOW
**And** the memo entry is consumed

#### Scenario: Fresh navigation to the same URL after the reissue resolved

**Given** the user navigated to URL `X`, was cancelled-and-reissued, and the page loaded
**When** the user later taps a link to URL `X` again
**Then** the memo entry no longer exists (was consumed)
**And** the bypass fires again (cancel + reissue)

#### Scenario: Memo entry expires after 2 seconds

**Given** the bypass cancelled URL `X` but the reissued navigation never arrived (e.g. user navigated away mid-flight)
**When** another navigation to `X` happens 5 seconds later
**Then** the memo entry has expired
**And** the bypass fires again

---

### Requirement: IOS-UL-004 - Header Forwarding

The system SHALL forward the original `URLRequest.headers` (e.g. per-site `Accept-Language`) when reissuing the navigation.

#### Scenario: Per-site Accept-Language survives the reissue

**Given** the site has `Accept-Language: de` configured
**And** the original navigation carried `Accept-Language: de` in its headers
**When** the bypass reissues the URL via `loadUrl`
**Then** the reissued request also carries `Accept-Language: de`

#### Scenario: POST body is dropped (acknowledged limitation)

**Given** a form POST navigation to a UL-matching URL
**When** the bypass cancels and reissues
**Then** the URL is reissued as a GET request
**And** the POST body is lost
**And** This is acknowledged as a rare-and-acceptable edge case — the prior behavior (iOS short-circuiting to the native app) lost the body anyway.

---

### Requirement: IOS-UL-005 - Platform Scope

The system SHALL apply the bypass only on iOS. Android, macOS, and Linux SHALL pass navigations through unchanged.

#### Scenario: Android navigation

**Given** the platform is Android
**When** the user taps a link
**Then** the bypass code path is not entered
**And** existing `intent://` external-scheme handling continues to apply via `ExternalUrlParser`

#### Scenario: macOS navigation

**Given** the platform is macOS
**When** WKWebView fires `decidePolicyForNavigationAction`
**Then** the bypass code path is not entered
**And** AASA is not a concern on macOS desktop browsers in practice

---

### Requirement: IOS-UL-006 - Nested Webview Coverage

The system SHALL apply the bypass equally to webviews opened via the cross-domain `InAppWebViewScreen` flow, not only the main app webviews.

#### Scenario: User taps a link that opens a nested webview to a UL-matching domain

**Given** the user is on Site A and taps a cross-domain link to a UL-matching URL
**When** WebSpace opens the URL in a nested `InAppWebViewScreen`
**Then** the nested webview's first navigation also runs through the bypass gate
**And** the page renders inside the nested webview rather than launching the native app

---

## Implementation Details

### IosUniversalLinkBypass

[`lib/services/ios_universal_link_bypass.dart`](../../../lib/services/ios_universal_link_bypass.dart) — pure-Dart class owning the per-URL memo. One instance per webview, allocated inside `WebViewFactory.createWebView`.

```dart
class IosUniversalLinkBypass {
  // URL → timestamp of last cancel-and-reissue.
  final Map<String, DateTime> _recentBypass = {};
  static const Duration _memoWindow = Duration(seconds: 2);

  // Returns true on first pass (caller cancels + reissues),
  // false on second pass (caller allows; memo entry consumed).
  bool shouldCancelAndReissue(String url, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final last = _recentBypass[url];
    if (last != null && t.difference(last) < _memoWindow) {
      _recentBypass.remove(url);
      return false;
    }
    _recentBypass[url] = t;
    return true;
  }
}
```

The class is the entire URL-matching surface: no domain or path filter. The webview-side gate decides eligibility (Platform, frame, scheme, gesture).

### Hook in shouldOverrideUrlLoading

[`lib/services/webview.dart`](../../../lib/services/webview.dart) — at the tail of `shouldOverrideUrlLoading`, after `_shouldBlockUrl`, captcha allowlist, `ExternalUrlParser`, DNS block, content blocker, ClearURLs, iframe pass-through, and the per-site `config.shouldOverrideUrlLoading` decision:

```dart
if (Platform.isIOS &&
    isMainFrame &&
    url.startsWith('http') &&
    _hasUserGesture(navigationAction)) {
  if (iosUlBypass.shouldCancelAndReissue(url)) {
    final originalUrl = navigationAction.request.url;
    final originalHeaders = navigationAction.request.headers;
    controller.loadUrl(urlRequest: inapp.URLRequest(
      url: originalUrl,
      headers: originalHeaders,
    ));
    return inapp.NavigationActionPolicy.CANCEL;
  }
  // Reissued nav passing through.
}
return inapp.NavigationActionPolicy.ALLOW;
```

`_hasUserGesture(navigationAction)` already returns true exactly for `LINK_ACTIVATED` / `FORM_SUBMITTED` on iOS — the same set of types iOS routes via AASA. This is the single eligibility filter.

### Why the bypass runs after all other policy checks

Putting the bypass at the tail means a URL that would otherwise be CANCELLED (DNS-blocked, content-blocker hit, cross-domain redirect with auto-redirect blocking, etc.) is cancelled before the bypass gets a chance to reissue it. The bypass only intervenes on URLs that were going to load anyway.

### Why programmatic loads don't trigger AASA

Per Apple's WKWebView documentation and observed behavior:

- Universal Links activate on `WKNavigationAction.navigationType == .linkActivated` or `.formSubmitted`, plus server-redirect chains that inherit those types.
- Programmatic navigations via `webView.load(URLRequest)` (which is what `controller.loadUrl` calls into) carry `navigationType == .other` and bypass AASA matching entirely.

The reissued navigation therefore renders inside the webview without any further intervention.

### Files

#### Created

- `lib/services/ios_universal_link_bypass.dart` — bypass class with anti-loop memo.
- `test/ios_universal_link_bypass_test.dart` — unit tests for the memo state machine.
- `openspec/specs/ios-universal-link-bypass/spec.md` — this spec.

#### Modified

- `lib/services/webview.dart` — bypass hook in `shouldOverrideUrlLoading`.

---

## Testing

Unit tests in [`test/ios_universal_link_bypass_test.dart`](../../../test/ios_universal_link_bypass_test.dart) cover the memo state machine: first pass triggers, second pass passes through, third pass triggers again, expiry, multi-URL independence, `clear()` resets, and (negatively) no domain filtering.

### Manual Test: Google Maps redirect doesn't open the native app

1. Install the Google Maps iOS app on the device.
2. In WebSpace, add `https://maps.google.com` as a site.
3. Open the site. The page should load inside the webview.
4. If a cookie consent banner appears (`consent.google.com`), accept it.
5. The redirect chain back to `www.google.com/maps` MUST render inside the webview.
6. The native Google Maps app MUST NOT open.

### Manual Test: Initial site load is not double-issued

1. With debug logging on, open any iOS site.
2. Check the logs for `shouldOverrideUrlLoading` → `-> ALLOW` for the initial URL.
3. There should NOT be a `-> CANCEL (iOS UL bypass: reissuing programmatically)` line — initial loads have `navigationType == .other` and skip the bypass.

### Manual Test: User-tap navigation goes through the bypass

1. With debug logging on, open a site and tap any link.
2. Check the logs for `-> CANCEL (iOS UL bypass: reissuing programmatically) <url>` followed by `-> ALLOW (iOS UL bypass: reissued nav passing through)`.

### Manual Test: Android passthrough unchanged

1. On Android, install Google Maps app and add `https://maps.google.com` as a WebSpace site.
2. Open the site and follow links.
3. The bypass MUST NOT fire (Android System WebView doesn't auto-launch apps for plain http(s)).
4. The existing `intent://` flow continues to handle external app launches with the user-confirmation dialog.

---

## Related

- [`navigation`](../navigation/spec.md) — main navigation orchestration.
- [`nested-url-blocking`](../nested-url-blocking/spec.md) — cross-domain navigation blocking; the bypass runs after this engine has decided the URL should load.
- [`per-site-cookie-isolation`](../per-site-cookie-isolation/spec.md) and [`per-site-containers`](../per-site-containers/spec.md) — the storage-isolation reason a user wants navigations to stay inside the WebSpace webview in the first place.

## Future Work

- A per-site or global toggle to **opt back in** to AASA routing for users who prefer the native-app affordance. Default: bypass on.
- A long-press affordance / explicit "Open in default app" menu item, surfaced from the URL bar, so users who want the native app can launch it without leaving WebSpace's gesture model.
