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

### Requirement: NESTED-008 - Route target="_blank" Through the Main-Frame Gesture Path

The system SHALL rewrite new-window anchor targets (`target="_blank"` /
`target="_new"`) on http(s) links to `_self` at capture phase, so a tapped
link is dispatched as a top-level navigation through
`shouldOverrideUrlLoading` instead of `onCreateWindow`.

**Rationale:** `supportMultipleWindows` is enabled for captcha popups
(see captcha-support). A side effect is that on Android a `target="_blank"`
tap is routed to `onCreateWindow`, where the user-gesture flag is
unreliable (frequently `false` for a genuine tap) and the request URL is
sometimes empty. The gesture-based cross-domain block (NESTED-004) then
silently cancels the navigation, so the link does nothing (issue #405).
iOS has the same divergence: `target="_blank"` taps often only fire
`onCreateWindow`. The top-level navigation path carries a reliable
per-request gesture signal on every platform.

**Scope:** only http(s) anchors are rewritten. `blob:` / `data:` /
external-scheme and `download` links are untouched (the blob-download
intercept and external-scheme handling own those). Script-driven
`window.open()` is not an anchor target and is unaffected — it still flows
through `onCreateWindow` with its existing captcha/gesture filtering.
Same-domain `target="_blank"` links already loaded in-place via the
`onCreateWindow` allow path, so the rewrite preserves their behavior.

Implementation: `lib/services/target_blank_rewrite.dart`
(`targetBlankRewriteScript`), injected always-on at `AT_DOCUMENT_START`,
`forMainFrameOnly: false`.

#### Scenario: Cross-domain target="_blank" link opens a nested webview

**Given** the user is on a page with an `<a target="_blank" href="https://other.example">` link
**When** the user taps the link
**Then** the anchor's target is rewritten to `_self` before the default action
**And** the navigation is dispatched through `shouldOverrideUrlLoading` with a user gesture
**And** the cross-domain destination opens in a nested webview (NESTED-004 "Direct link click allowed")

#### Scenario: Captcha popup still uses onCreateWindow

**Given** a site invokes `window.open()` for a Cloudflare/hCaptcha challenge
**When** the popup is requested
**Then** the rewrite does not apply (no anchor target involved)
**And** the challenge is handled by the existing `onCreateWindow` captcha path

---

### Requirement: NESTED-007 - Preserve Same-Domain Navigation

The system SHALL allow normal website navigation within the same domain regardless of gesture.

Uses normalized domain comparison with aliases (e.g., `mail.google.com` → `google.com`).

#### Scenario: Normal internal navigation

**Given** a user is on example.com/page1
**When** they click a link to example.com/page2
**Then** navigation proceeds normally

---

### Requirement: NESTED-009 - Per-Site Open External Links in System Browser

The system SHALL provide a per-site setting that opens a cross-domain link
not covered by the site's domain claims in the device's default browser
instead of a nested in-app webview.

**Field**: `externalLinksInBrowser` (default: `false`)

When enabled, a navigation that the cross-domain decision would route to a
nested webview (NESTED-004 "Direct link click allowed") is instead handed to
the system browser via `url_launcher`, UNLESS the target matches one of the
site's `effectiveDomainClaims` (link-intent-routing) — a claimed domain still
opens in a nested webview. The `blockAutoRedirects` silent block and the
background-site suppression take precedence, so a gesture-less script redirect
or a background site never pops the system browser. Archive-tier sites force
the setting off (`effectiveExternalLinksInBrowser`, ARCH-006): handing a URL to
another app crosses the archive isolation boundary.

This implements discussion #438: "a setting for each site to have any link
inside a web app that is not a domain claim for that website to open in the
system's default browser." The complementary request — that links opened
in-app are not added as domain claims — already holds: in-app navigation never
mutates `domainClaims`; claims change only through the per-site editor or the
user-initiated inbound bind picker (link-intent-routing LIR-010).

#### Scenario: Unclaimed cross-domain link opens in the system browser

**Given** a site `https://example.com` with `externalLinksInBrowser` on
**And** the user taps a link to `https://unclaimed.com` (cross-domain, not a claim)
**When** `shouldOverrideUrlLoading` runs
**Then** the navigation is cancelled
**And** the URL is handed to the device's default browser
**And** no nested webview opens

#### Scenario: Claimed cross-domain link stays in the app

**Given** a "Google" site whose domain claims include `youtube.com`
**And** `externalLinksInBrowser` is on
**When** the user taps a `https://youtube.com/...` link
**Then** the link opens in a nested webview (it matches a domain claim), not the system browser

#### Scenario: Setting off preserves legacy routing

**Given** a site with `externalLinksInBrowser` off (the default)
**When** the user taps a cross-domain link
**Then** it opens in a nested webview exactly as before

#### Scenario: Gesture-less script redirect is not launched externally

**Given** a site with `externalLinksInBrowser` on and `blockAutoRedirects` on
**When** a script fires a cross-domain navigation with no user gesture
**Then** the navigation is silently cancelled (NESTED-004) and the system browser is NOT opened

#### Scenario: Nested webview honors the setting

**Given** a claimed cross-domain link opened a nested webview while the setting is on
**When** the user taps a link in that nested webview pointing to a different domain than the page shown
**Then** that link opens in the system browser (NESTED-009 applies in nested screens too)

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
  │   ├─ background site ───────────────── CANCEL (suppressed)
  │   ├─ externalLinksInBrowser + not a claim ── CANCEL + system browser (NESTED-009)
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
- Registers `targetBlankRewriteScript` always-on at `AT_DOCUMENT_START`

#### `lib/services/target_blank_rewrite.dart`
- `targetBlankRewriteScript` — capture-phase click shim that rewrites
  http(s) `target="_blank"` / `_new` anchors to `_self`, routing taps
  through the reliable main-frame gesture path (NESTED-008). Behaviour
  proven in `test/js/target_blank_rewrite.test.js`; string shape +
  registration guarded by `test/target_blank_rewrite_test.dart`.

#### `lib/web_view_model.dart`
- `blockAutoRedirects` field (default: `true`)
- `externalLinksInBrowser` field (default: `false`) + `effectiveExternalLinksInBrowser` getter (forced off for archive tier, NESTED-009 / ARCH-006). Serialized only when true (`toJson` omits the default)
- `shouldOverrideUrlLoading` callback: delegates to `NavigationDecisionEngine`, applies the returned `GestureStateUpdate` to `lastSameDomainGestureTime`, dispatches on the decision enum (log + `launchUrlFunc` for `blockOpenNested`, `launchUrlInSystemBrowser` for `blockOpenExternal`)
- `onUrlChanged` callback: same pattern; on `blockOpenNested` navigates back to `previousSameDomainUrl` before opening the nested webview
- `matchesSiteClaim` closure passes `effectiveDomainClaims` to the engine via `LinkRoutingService.urlMatchesAnyClaim` so a claimed cross-domain link stays nested even with `externalLinksInBrowser` on
- Serialized in `toJson()` / `fromJson()` with `?? true` for backward compat

#### `lib/services/navigation_decision_engine.dart`
- `NavigationDecision.blockOpenExternal` — cancel + hand to system browser
- `decideShouldOverrideUrlLoading` / `decideOnUrlChanged` take optional `externalLinksInBrowser` + `matchesSiteClaim`; when the decision would be `blockOpenNested` and the setting is on and the target is unclaimed, returns `blockOpenExternal`
- `OnUrlChangedHandled.launchExternalUrl` carries the URL for the caller to launch

#### `lib/screens/inappbrowser.dart`
- `externalLinksInBrowser` ctor field; nested `WebViewConfig.shouldOverrideUrlLoading` (gated on the setting, null when off) routes user-gesture cross-domain navigations to `launchUrlInSystemBrowser`, judged against the page currently shown

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
