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
