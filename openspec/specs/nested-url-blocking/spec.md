# Nested Webview URL Blocking Specification

## Purpose

Prevents unwanted nested webviews from being created for tracking URLs, analytics, service workers, popups, and script-initiated cross-domain navigations while maintaining functionality for legitimate use cases like Cloudflare challenges and user-clicked links.

## Status

- **Date**: 2026-03-08
- **Status**: In Progress

---

## Problem Statement

When opening certain websites, unwanted nested webviews are created for:
- `about:blank` / `about:srcdoc` iframes
- Cloudflare DNS challenges
- Google Tag Manager service worker iframes
- Script-initiated cross-domain navigations (Google One Tap, Stripe fraud detection, analytics redirects)

On desktop browsers, third-party auth (Google Sign-In) uses popups via `window.open()`. In a mobile webview, `window.open()` is dismissed, so scripts fall back to redirect-based flows, triggering top-level navigations to `accounts.google.com` etc.

### Observed Cases

| Site | Script | Navigation Target | Trigger |
|------|--------|-------------------|---------|
| X.com | Google GSI (`googleGSILibrary`) | accounts.google.com | Auto (Google One Tap) |
| Reddit | Google GSI | accounts.google.com | Auto (Google One Tap) |
| Hugging Face | Stripe.js | js.stripe.com, m.stripe.network | Auto (fraud detection) |
| Various | Google Tag Manager | googletagmanager.com | Auto (analytics) |

---

## Requirements

### Requirement: NESTED-001 - Disable Multiple Windows

The system SHALL disable automatic nested window creation via `window.open()`.

#### Scenario: Block popup window creation

**Given** a website attempts to open a popup via window.open()
**When** the popup request is intercepted
**Then** no nested webview is created
**And** captcha challenges (Cloudflare, hCaptcha, reCAPTCHA) are still allowed

---

### Requirement: NESTED-002 - Block about: Protocol URLs

The system SHALL block `about:` protocol URLs except `about:blank` and `about:srcdoc` (required for Cloudflare Turnstile iframes).

#### Scenario: Block about: URLs

**Given** a page triggers navigation to an about: URL
**When** the URL is not `about:blank` or `about:srcdoc`
**Then** the navigation is cancelled

---

### Requirement: NESTED-003 - Block Service Worker Iframes

The system SHALL block service worker and tracking iframes.

Blocked patterns:
- `/sw_iframe.html`
- `/blank.html`
- `/service_worker/`

#### Scenario: Block Google Tag Manager service worker

**Given** a page loads Google Tag Manager
**When** GTM tries to create a service worker iframe
**Then** the iframe creation is blocked

---

### Requirement: NESTED-004 - Block Script-Initiated Cross-Domain Navigations

The system SHALL block cross-domain navigations that lack a user gesture, preventing automatic nested webview creation.

This replaces the previous hardcoded `_trackingDomains` blocklist (Stripe, analytics domains) with gesture-based detection using `NavigationAction.hasGesture`.

**Note:** A user tap on "Sign in with Google" has `hasGesture = true`, but the resulting script-initiated navigation to `accounts.google.com` may have `hasGesture = false`. This means gesture detection can block user-intended OAuth flows. This is a known limitation — users can disable blocking per-site via the `blockAutoRedirects` toggle (NESTED-006).

#### Scenario: Google One Tap blocked

**Given** the user is viewing x.com (not logged in)
**And** X.com loads the Google GSI library
**When** GSI triggers a navigation to accounts.google.com on page load
**And** the navigation has no user gesture
**Then** the navigation is silently cancelled
**And** no nested webview opens

#### Scenario: Direct link click allowed

**Given** the user is viewing a page with an external link
**When** the user taps the link (hasGesture = true)
**Then** the navigation opens in a nested webview

---

### Requirement: NESTED-005 - Allow Captcha Challenges

The system SHALL allow captcha/challenge URLs regardless of gesture.

Supported challenges:
- Cloudflare (`challenges.cloudflare.com`, `cdn-cgi/challenge-platform`, `cf-turnstile`)
- hCaptcha (`hcaptcha.com`)
- reCAPTCHA (`/recaptcha/` on `google.com`, `gstatic.com`, `recaptcha.net`, `googleapis.com`)

#### Scenario: Complete Cloudflare challenge

**Given** a site is protected by Cloudflare
**When** a challenge is triggered
**Then** the challenge loads in the main webview (not nested)
**And** the user can complete the challenge

---

### Requirement: NESTED-006 - Per-Site Toggle for Auto-Redirect Blocking

The system SHALL provide a per-site setting to disable auto-redirect blocking.

**Field**: `blockAutoRedirects` (default: `true`)

#### Scenario: User disables blocking for a site

**Given** the user has a site where auto-redirects are needed (e.g., an OAuth callback flow)
**When** the user disables "Block auto-redirects" in site settings
**Then** all cross-domain navigations open in nested webviews regardless of gesture

---

### Requirement: NESTED-007 - Preserve Same-Domain Navigation

The system SHALL allow normal website navigation within the same domain regardless of gesture.

Uses normalized domain comparison with aliases (e.g., `mail.google.com` → `google.com`).

#### Scenario: Normal internal navigation

**Given** a user is on example.com/page1
**When** they click a link to example.com/page2
**Then** navigation proceeds normally

---

## Implementation

### Decision Flow in shouldOverrideUrlLoading

```
URL received
  │
  ├─ _shouldBlockUrl? ──────────────── CANCEL (about:, service workers)
  ├─ isCaptchaChallenge? ───────────── ALLOW
  ├─ DNS blocklist hit? ────────────── CANCEL
  ├─ Content blocker hit? ──────────── CANCEL
  ├─ ClearURLs rewrite? ───────────── CANCEL (reload cleaned)
  │
  ├─ Same domain? ──────────────────── ALLOW
  │
  ├─ Cross-domain:
  │   ├─ blockAutoRedirects + no gesture ── CANCEL (silent)
  │   ├─ blockAutoRedirects OFF ────────── open nested webview
  │   └─ has gesture ──────────────────── open nested webview
  │
  └─ ALLOW
```

### Gesture Detection

`flutter_inappwebview`'s `NavigationAction` provides platform-specific gesture info. The `_hasUserGesture()` helper normalizes this:

- **Android**: `hasGesture` (bool) — `true` when navigation triggered by user tap
- **iOS/macOS**: `navigationType` — `LINK_ACTIVATED` or `FORM_SUBMITTED` for user-initiated navigations, `OTHER` for script-initiated
- **Fallback**: defaults to `true` (allow) on unknown platforms

```dart
static bool _hasUserGesture(NavigationAction action) {
  if (Platform.isAndroid) {
    return action.hasGesture ?? true;
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return action.navigationType == NavigationType.LINK_ACTIVATED ||
           action.navigationType == NavigationType.FORM_SUBMITTED;
  }
  return true;
}
```

### Files

#### `lib/services/navigation_decision_engine.dart`
- `NavigationDecisionEngine.decideShouldOverrideUrlLoading` — pure
  decision for the `shouldOverrideUrlLoading` callback; returns one of
  `allow` / `blockSilent` / `blockSuppressed` / `blockOpenNested` plus
  an optional `GestureStateUpdate` descriptor. Implements NESTED-004
  (script-initiated cross-domain blocking), NESTED-006 (per-site
  `blockAutoRedirects` toggle), and NESTED-007 (same-domain
  propagation + 10s gesture window).
- `NavigationDecisionEngine.decideOnUrlChanged` — same decision
  shape for server-side 3xx redirects that bypass
  `shouldOverrideUrlLoading`. `isCaptchaChallenge` is injected as a
  callback so the engine has no transitive import of the captcha
  domain list.

Both the production callbacks in `lib/web_view_model.dart` AND the
`NavigationTestHarness` in
[test/nested_webview_navigation_test.dart](../../../test/nested_webview_navigation_test.dart)
delegate to this engine — before extraction the harness carried an
inline copy of the same decision tree, which is exactly the DRY smell
CLAUDE.md now forbids. Direct engine tests live in
[test/navigation_decision_engine_test.dart](../../../test/navigation_decision_engine_test.dart).

#### `lib/services/webview.dart`
- `_shouldBlockUrl()` — blocks `about:` (except blank/srcdoc) and service worker patterns
- `isCaptchaChallenge()` — detects captcha domains and paths; passed to `decideOnUrlChanged` as a callback
- `shouldOverrideUrlLoading` callback passes `hasGesture` from `NavigationAction`
- `onCreateWindow` — dismisses all `window.open()` except captcha challenges

#### `lib/web_view_model.dart`
- `blockAutoRedirects` field (default: `true`)
- `shouldOverrideUrlLoading` callback: delegates to `NavigationDecisionEngine`, applies the returned `GestureStateUpdate` to `lastSameDomainGestureTime`, dispatches on the decision enum (log + `launchUrlFunc` for `blockOpenNested`)
- `onUrlChanged` callback: same pattern; on `blockOpenNested` navigates back to `previousSameDomainUrl` before opening the nested webview
- Serialized in `toJson()` / `fromJson()` with `?? true` for backward compat

#### `lib/screens/settings.dart`
- "Block auto-redirects" toggle per site

---

## Testing

### Manual Test: Google One Tap Blocked

1. Add x.com as a site (not logged in)
2. Load the page
3. Verify no nested webview opens for accounts.google.com
4. Verify the page functions normally

### Manual Test: Per-Site Toggle

1. Open site settings for any site
2. Toggle "Block auto-redirects" off
3. Reload the site
4. Verify script-initiated cross-domain navigations now open nested webviews
