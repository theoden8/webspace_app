# Captcha Support Specification

## Purpose

This specification documents the WebView settings and behaviors required to support captcha systems like Cloudflare Turnstile, hCaptcha, and reCAPTCHA.

## Status

- **Status**: In Progress

---

## Requirements

### Requirement: CAPTCHA-001 - JavaScript and DOM Storage

The WebView MUST have JavaScript and DOM storage enabled to support captcha systems.

#### Scenario: Enable JavaScript and storage

**Given** a site uses a captcha system
**When** the WebView loads the page
**Then** JavaScript is enabled
**And** DOM storage is enabled
**And** database storage is enabled

---

### Requirement: CAPTCHA-002 - Allow Required URLs

The WebView MUST allow `about:blank` and `about:srcdoc` URLs for captcha iframe rendering.

#### Scenario: Allow about:blank

**Given** a captcha iframe requests `about:blank`
**When** the navigation is evaluated
**Then** the request is allowed (not blocked)

#### Scenario: Allow about:srcdoc

**Given** a captcha iframe requests `about:srcdoc`
**When** the navigation is evaluated
**Then** the request is allowed (not blocked)

#### Scenario: Block other about: URLs

**Given** a request for `about:invalid` or other about: URLs
**When** the navigation is evaluated
**Then** the request is blocked

---

### Requirement: CAPTCHA-003 - Android File and Content Access

On Android, the WebView MUST have file and content access enabled for captcha implementations.

#### Scenario: Enable file access on Android

**Given** the app is running on Android
**When** a WebView is created
**Then** `allowFileAccess` is enabled
**And** `allowContentAccess` is enabled

---

### Requirement: CAPTCHA-004 - Popup Window Support

The WebView MUST support popup windows (`window.open()`) for captcha verification flows.

#### Scenario: Support window.open() for captcha

**Given** a captcha requests a popup window via `window.open()`
**When** the WebView receives the request
**Then** a popup WebView is created with the correct windowId
**And** the popup is displayed to the user
**And** the popup can be closed when verification completes

---

### Requirement: CAPTCHA-005 - Consistent User Agent

The WebView MUST maintain a consistent user agent throughout the session to prevent captcha failures.

#### Scenario: Maintain consistent user agent

**Given** a site has a captcha challenge
**When** the user interacts with the captcha
**Then** the user agent remains consistent throughout the session
**And** the default WebView user agent is used (not modified)

---

### Requirement: CAPTCHA-006 - Third-Party Cookies (Optional)

The WebView MUST support third-party cookies when enabled per-site for captcha systems that require them.

#### Scenario: Third-party cookies available when enabled

**Given** a site has third-party cookies enabled in settings
**When** a captcha iframe sets a cookie
**Then** the cookie is accepted

---

### Requirement: CAPTCHA-007 - Captcha detection is scoped, never a substring of the whole URL

A URL classified as a captcha challenge is allowed in place and may open a
popup window, so the classifier decides how much of the navigation
pipeline a URL skips. It SHALL parse the URL and decide on host and
**path** only. The two Cloudflare markers (`/cdn-cgi/challenge-platform`,
`cf-turnstile`) are served from the protected origin itself, so they stay
host-agnostic but SHALL match `uri.path`; `challenges.cloudflare.com` /
`hcaptcha.com` stay exact-domain, and `/recaptcha/` stays path-plus-domain.

#### Scenario: An attacker-chosen query string is not a captcha

**Given** a page links to `https://evil.example/x?cf-turnstile`
**When** the URL is classified
**Then** it is not a captcha challenge

#### Scenario: A Cloudflare interstitial on the protected origin is a captcha

**Given** a Cloudflare-fronted site serves
`https://acme.example/cdn-cgi/challenge-platform/h/b/jsd/r/...`
**When** the URL is classified
**Then** it is a captcha challenge

---

### Requirement: CAPTCHA-008 - The captcha allow follows the navigation decision

The captcha allow SHALL be applied **after** the navigation verdict, in
**both** interception paths — a fix to one leaves the other open, since
`onUrlChanged` catches exactly the server-side and script-driven
navigations that `shouldOverrideUrlLoading` did not:

- `shouldOverrideUrlLoading` — after `config.shouldOverrideUrlLoading`
  (the nested-url-blocking engine, see
  [nested-url-blocking](../nested-url-blocking/spec.md)) has returned.
- `NavigationDecisionEngine.decideOnUrlChanged` — after the
  `blockAutoRedirects && !hasRecentGesture` branch.

Taken first, a URL that merely looks like a captcha would skip
`blockAutoRedirects`, the user-gesture requirement and cross-domain nested
routing, and could navigate the parent webview to any origin — inside the
site's own container, and committed as its persisted `currentUrl`.

#### Scenario: A captcha-shaped URL still goes through the routing decision

**Given** a site with `blockAutoRedirects` on
**And** a script-driven navigation to a cross-domain URL whose path
contains a Cloudflare marker
**When** `shouldOverrideUrlLoading` runs
**Then** the navigation decision engine sees the URL
**And** its verdict is honored before the captcha allow is considered

#### Scenario: The onUrlChanged path enforces the same order

**Given** a site with `blockAutoRedirects` on and no recent gesture
**When** `onUrlChanged` fires for
`https://attacker.example/cdn-cgi/challenge-platform/x`
**Then** `decideOnUrlChanged` returns `blockSilent`

#### Scenario: A genuine interstitial is unaffected

**Given** the same site
**When** `onUrlChanged` fires for
`https://site.example/cdn-cgi/challenge-platform/h/b/orchestrate`
**Then** the same-domain check returns `allow` before the captcha branch is
reached

---

### Requirement: CAPTCHA-009 - The popup inherits the requesting site's posture

The captcha popup created for an `onCreateWindow` window id is the same
site in a dialog. `createPopupWebView` SHALL build it from the requesting
webview's `WebViewConfig`: the same `initialUserScripts` (and the Dart
handlers they call), `userAgent`, `javaScriptEnabled`, `incognito`,
`thirdPartyCookiesEnabled`, container binding and per-site proxy. With no
recorded parent config, or with a per-site proxy the platform cannot
honor, it SHALL render nothing rather than a webview with no posture.

#### Scenario: Popup carries the site's shims and identity

**Given** site "Acme" has tracking protection, a spoofed UA and a
per-site container
**When** a captcha flow on "Acme" opens a popup window
**Then** the popup webview is bound to "Acme"'s container
**And** it is injected with the same user scripts as "Acme"'s webview
**And** it reports "Acme"'s user agent

#### Scenario: Popup is not created without a posture to inherit

**Given** `createPopupWebView` is called for a window id with no recorded
parent config
**When** the widget is built
**Then** no webview is created

---

## Known Limitations

### Cloudflare Turnstile Cross-Origin Access

Some Cloudflare Turnstile implementations attempt **direct cross-origin frame access** which is blocked by the browser's Same-Origin Policy. This is a fundamental browser security feature that:

1. **Cannot be bypassed** via WebView settings
2. **Affects all WebView-based browsers** (not just this app)
3. **Is intentional** - preventing cross-origin frame access is a core security feature

**Error message:**
```
Blocked a frame with origin "https://challenges.cloudflare.com" from accessing a frame with origin "https://example.com"
```

**Workaround:** Users can try enabling third-party cookies for the affected site.

---

## WebView Settings Summary

| Setting | Value | Purpose |
|---------|-------|---------|
| `javaScriptEnabled` | `true` | Required for all captchas |
| `domStorageEnabled` | `true` | Required for captcha state |
| `databaseEnabled` | `true` | Required for some captchas |
| `supportMultipleWindows` | `true` | For popup-based challenges |
| `javaScriptCanOpenWindowsAutomatically` | `true` | For popup-based challenges |
| `allowFileAccess` | `true` | Android: Cloudflare requirement |
| `allowContentAccess` | `true` | Android: Cloudflare requirement |
| `thirdPartyCookiesEnabled` | configurable | Per-site setting |

---

## URL Blocking Rules

The following `about:` URLs are allowed for captcha support:
- `about:blank` - Used by captcha iframes
- `about:srcdoc` - Used by captcha iframes

All other `about:` URLs are blocked.

---

## Files

### Modified
- `lib/services/webview.dart` - WebView settings and URL filtering (`_shouldBlockUrl`)
- `lib/web_view_model.dart` - Allow about:blank/srcdoc in `shouldOverrideUrlLoading` callback

### Related Specs
- `openspec/specs/cookie-secure-storage/spec.md` - Cookie handling

---

## References

- [Cloudflare Turnstile Mobile Implementation](https://developers.cloudflare.com/turnstile/get-started/mobile-implementation/)
- [flutter_inappwebview Issue #1738](https://github.com/pichillilorenzo/flutter_inappwebview/issues/1738)
