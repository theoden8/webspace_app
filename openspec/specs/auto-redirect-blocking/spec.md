# Auto-Redirect Blocking Specification

## Purpose

Block cross-domain navigations that are triggered automatically (by scripts) rather than by explicit user clicks. This prevents unwanted nested webviews from opening for Google Sign-In prompts, Stripe fraud detection iframes, analytics redirects, and similar script-initiated navigations.

## Status

- **Date**: 2026-03-08
- **Status**: In Progress

---

## Problem Statement

Sites like X.com, Reddit, and Hugging Face load third-party scripts (Google GSI, Stripe.js, etc.) that trigger automatic cross-domain navigations. These navigations hit `shouldOverrideUrlLoading`, where the app sees a different domain and opens a nested webview — even though the user never clicked anything.

### Current Workarounds (to be replaced)

1. **`_trackingDomains` hardcoded blocklist** in `webview.dart` — manually lists Stripe domains (`js.stripe.com`, `js.stripe.dev`, `m.stripe.network`, etc.) and analytics domains. Fragile and incomplete.
2. **`onCreateWindow` blanket block** — silently dismisses all `window.open()` calls except captcha challenges. This works but is coarse.

### Root Cause

On desktop browsers, third-party auth (Google Sign-In, Apple Sign-In) uses **popups** via `window.open()`. In a mobile webview:
- `window.open()` is caught by `onCreateWindow` and dismissed (existing behavior)
- The scripts fall back to **redirect-based flows**, triggering top-level navigations to `accounts.google.com` etc.
- These are script-initiated (no user gesture), but `shouldOverrideUrlLoading` treats them the same as user clicks

### Observed Cases

| Site | Script | Navigation Target | Trigger |
|------|--------|-------------------|---------|
| X.com | Google GSI (`googleGSILibrary`) | accounts.google.com | Auto (Google One Tap / Sign-In button render) |
| Reddit | Google GSI | accounts.google.com | Auto (Google One Tap) |
| Hugging Face | Stripe.js | js.stripe.com, m.stripe.network | Auto (fraud detection) |
| Various | Google Tag Manager | googletagmanager.com | Auto (analytics) |

---

## Requirements

### Requirement: ARB-001 - Block Script-Initiated Cross-Domain Navigations

The system SHALL block cross-domain navigations that lack a user gesture, preventing automatic nested webview creation.

#### Scenario: Google One Tap blocked

**Given** the user is viewing x.com (not logged in)
**And** X.com loads the Google GSI library
**When** GSI triggers a navigation to accounts.google.com
**And** the navigation has no user gesture (`hasGesture == false` on Android, `navigationType != LINK_ACTIVATED` on iOS)
**Then** the navigation is silently cancelled
**And** no nested webview opens

#### Scenario: User-clicked Google Sign-In allowed

**Given** the user is viewing x.com
**When** the user taps the "Sign up with Google" button
**And** a navigation to accounts.google.com is triggered with a user gesture
**Then** the navigation opens in a nested webview as normal

---

### Requirement: ARB-002 - Per-Site Toggle

The system SHALL provide a per-site setting to disable auto-redirect blocking.

**Field**: `blockAutoRedirects` (default: `true`)

#### Scenario: User disables blocking for a site

**Given** the user has a site where auto-redirects are needed (e.g., an OAuth callback flow)
**When** the user disables "Block auto-redirects" in site settings
**Then** all cross-domain navigations open in nested webviews regardless of gesture

---

### Requirement: ARB-003 - Remove Hardcoded Domain Blocklist

The system SHALL remove the `_trackingDomains` list from `webview.dart`, as gesture-based detection makes domain-specific blocking unnecessary for navigation control.

Note: DNS blocklist and content blocker already handle domain-level blocking for ads/trackers at a different layer. The `_trackingDomains` list was a workaround specifically for unwanted nested webviews.

---

### Requirement: ARB-004 - Preserve Captcha and Same-Domain Navigation

The system SHALL continue to allow:
- Captcha/challenge URLs (Cloudflare, hCaptcha, reCAPTCHA) regardless of gesture
- Same-domain navigations regardless of gesture
- `about:blank` and `about:srcdoc` for iframe support

---

## Implementation

### Gesture Detection

`flutter_inappwebview`'s `NavigationAction` provides:
- **Android**: `hasGesture` (bool) — `true` when navigation triggered by user tap
- **iOS**: `navigationType` — `LINK_ACTIVATED` for user-clicked links

```dart
bool hasUserGesture(NavigationAction action) {
  if (Platform.isAndroid) {
    return action.hasGesture ?? true; // default allow if null
  }
  if (Platform.isIOS || Platform.isMacOS) {
    return action.navigationType == NavigationType.LINK_ACTIVATED;
  }
  return true; // default allow on unknown platforms
}
```

### Decision Flow in shouldOverrideUrlLoading

```
URL received
  │
  ├─ _shouldBlockUrl? ──────────────────── CANCEL (about:, service workers)
  ├─ isCaptchaChallenge? ───────────────── ALLOW
  ├─ DNS blocklist hit? ────────────────── CANCEL
  ├─ Content blocker hit? ──────────────── CANCEL
  ├─ ClearURLs rewrite? ───────────────── CANCEL (reload cleaned)
  │
  ├─ Same domain? ──────────────────────── ALLOW
  │
  ├─ Cross-domain:
  │   ├─ blockAutoRedirects ON + no gesture ── CANCEL (silent)
  │   ├─ blockAutoRedirects OFF ────────────── open nested webview
  │   └─ has gesture ──────────────────────── open nested webview
  │
  └─ ALLOW
```

### Modified Files

#### `lib/services/webview.dart`
- Remove `_trackingDomains` list (Stripe, analytics domains)
- Remove `_shouldBlockUrl` tracking domain checks (keep `about:` and service worker checks)
- Pass `hasGesture` info through `shouldOverrideUrlLoading` callback
- Change callback signature: `Function(String url, bool hasGesture)? shouldOverrideUrlLoading`

#### `lib/web_view_model.dart`
- Add `blockAutoRedirects` field (default: `true`)
- In `shouldOverrideUrlLoading` callback: check gesture before opening nested webview
- Add to `toJson()` / `fromJson()` with `?? true` for backward compat
- Add to `getWebView()` parameter propagation

#### `lib/screens/settings.dart`
- Add "Block auto-redirects" toggle after existing DNS/content blocker toggles

#### `lib/screens/inappbrowser.dart`
- Propagate `blockAutoRedirects` parameter

#### `lib/main.dart`
- Pass `blockAutoRedirects` through `_launchUrl` and `getWebView` calls

---

## What Gets Blocked (automatically, no hardcoded list needed)

- Google One Tap / GSI sign-in prompts
- Stripe fraud detection frames
- Analytics redirects
- Any script-initiated cross-domain navigation

## What Still Works

- User-clicked external links (open in nested webview)
- Captcha challenges (Cloudflare, hCaptcha, reCAPTCHA)
- Same-domain navigation
- Sites with blocking disabled via per-site toggle

---

## Testing

### Manual Test: Google One Tap Blocked

1. Add x.com as a site (not logged in)
2. Load the page
3. Verify no nested webview opens for accounts.google.com
4. Tap "Sign up with Google" button manually
5. Verify nested webview opens for accounts.google.com

### Manual Test: Per-Site Toggle

1. Open site settings for any site
2. Toggle "Block auto-redirects" off
3. Reload the site
4. Verify script-initiated cross-domain navigations now open nested webviews

### Manual Test: Stripe No Longer Hardcoded

1. Visit huggingface.co
2. Verify no nested webview opens for stripe.com domains
3. Verify the site functions normally
