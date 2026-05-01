# External Scheme Handling Specification

## Status

- **Date**: 2026-05-01
- **Status**: Implemented
- **Scope**: All platforms

## Purpose

Decide what happens when a webview tries to navigate to a URL whose scheme the webview itself cannot render: `intent://`, `tel:`, `mailto:`, `market:`, `fb://`, custom-app deep links, etc. Two competing concerns:

1. **We are the browser.** When a site fires `intent://www.google.com/maps?…#Intent;scheme=https;…;S.browser_fallback_url=https://www.google.com/maps?…;end`, the user is *already* inside their chosen browser. Punting them out to the native Maps app contradicts what they configured WebSpace to do, loses per-site cookies/proxy/blockers, and (Google Maps does this every visit) spams a confirmation prompt the user keeps cancelling.
2. **Some intents really ARE for an unsupported scheme.** A QR-code page firing `intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end` legitimately wants the scanner app — there is no http(s) equivalent the webview could load instead. The user must still be able to pick "open in app".

The split is "is there a resolvable web URL?". If yes → silent route through the standard navigation path. If no → existing confirmation dialog.

---

## Problem Statement

Pre-existing behavior: every `intent://` (and every other non-internal scheme) opened the same `_ExternalUrlChoice` dialog with three buttons — Cancel / Open in browser / Open in app. Two failure modes:

- **Google Maps spam.** Mobile Google Maps fires its `intent://www.google.com/maps?…` redirect on every page view. Even with `ExternalUrlSuppressor` damping repeats, the user sees the prompt the first time on every visit. The fallback URL is always `https://www.google.com/maps?…` — a URL the webview *is already showing* — so the prompt is asking "do you want to open this app you don't have for a URL you're already on?".
- **"Open in browser" lied.** The button called `url_launcher.launchUrl(…, mode: externalApplication)`, handing the URL to the system default browser. WebSpace *is* the browser the user picked. The handoff lost per-site settings (cookie isolation, proxy, content blocker) and dropped the user into a different app for no reason.

---

## Solution

Two changes in `lib/services/webview.dart` and one in `lib/widgets/external_url_prompt.dart`:

1. **Resolve `intent://` to its web equivalent** via `ExternalUrlParser.intentToWebUrl(info)`:
   - Prefer the explicit `S.browser_fallback_url` extra (must parse as `http`/`https`).
   - Otherwise reconstruct from `targetScheme://host[:port]/path?query` when `targetScheme` is `http` or `https`.
   - Return `null` for everything else (zxing, custom app schemes, file://, etc.).
2. **At every intent intercept point** (`shouldOverrideUrlLoading`, `onCreateWindow`, `onReceivedError`):
   - If `intentToWebUrl` returns non-null → call back into `config.shouldOverrideUrlLoading(resolved, hasGesture)`. Same base domain → `controller.loadUrl(resolved)` here. Cross-domain → the callback already issued `launchUrl(resolved)` for a nested webview. No prompt.
   - If `intentToWebUrl` returns null → fall through to `config.onExternalSchemeUrl(url, info)`, the existing prompt flow.
3. **"Open in browser" loads in this webview.** `confirmAndLaunchExternalUrl` accepts an optional `WebViewController? loadInWebView`. When non-null and the cleaned fallback is non-empty, the button calls `loadInWebView.loadUrl(cleanedFallback)`; on failure (or when no controller is available, e.g. tel:/mailto: with no fallback), it falls back to `url_launcher.launchUrl(…, externalApplication)`.

### Why route through the existing `shouldOverrideUrlLoading` callback

The host already wires that callback to a same-domain / cross-domain decision: same domain → `ALLOW`, cross-domain → `CANCEL` plus an inline `launchUrlFunc(url, …)` that opens a nested `InAppWebViewScreen` with all per-site fields propagated. Re-entering that callback with the resolved URL means an intent fallback inherits the exact same routing rules as a regular `<a href="https://…">` click — no parallel decision tree to keep in sync.

### Why `onReceivedError` needs the same treatment

On Android, intent navigations sometimes skip `shouldOverrideUrlLoading` entirely and surface as an `ERR_UNKNOWN_URL_SCHEME` in `onReceivedError` (every Google Maps `window.location='intent://…'` JS redirect, observed). Without the same intent-resolve step, the user would see the chrome error page until the page re-fired the intent and finally got intercepted at the `shouldOverrideUrlLoading` layer.

### Why file:// is excluded from the fallback allowlist

A web origin must not be able to convince the webview to load a `file://` URL via the intent dance: classic local-file disclosure. `intentToWebUrl` only accepts `http` and `https` for both the explicit `browser_fallback_url` and the reconstructed URL. Intents with `scheme=file` or a `file://` fallback drop into the prompt path; the user can still launch externally if they really want to.

---

## Requirements

### Requirement: EXT-001 - Intent URL Parsing

The system SHALL parse `intent://` URLs into structured `ExternalUrlInfo` records exposing `host`, `package`, `fallbackUrl`, and `targetScheme` per the Chrome intent scheme spec.

#### Scenario: Google Maps intent with fallback URL

**Given** the URL `intent://www.google.com/maps?entry=ml#Intent;scheme=https;package=com.google.android.apps.maps;S.browser_fallback_url=https%3A%2F%2Fwww.google.com%2Fmaps%3Fentry%3Dml;end;`
**When** `ExternalUrlParser.parse` is called
**Then** the returned info has `scheme=intent`, `host=www.google.com`, `package=com.google.android.apps.maps`, `targetScheme=https`, `fallbackUrl=https://www.google.com/maps?entry=ml`

#### Scenario: Scanner intent without web fallback

**Given** the URL `intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end`
**When** `ExternalUrlParser.parse` is called
**Then** the info has `targetScheme=zxing`, `fallbackUrl=null`

---

### Requirement: EXT-002 - Intent Resolution to Web URL

The system SHALL provide `ExternalUrlParser.intentToWebUrl(info)` that returns an `http`/`https` equivalent of an intent, or `null` when none exists.

#### Scenario: Prefer explicit browser_fallback_url

**Given** an `ExternalUrlInfo` with `scheme=intent`, `targetScheme=https`, `fallbackUrl=https://www.google.com/maps?entry=ml`
**When** `intentToWebUrl(info)` is called
**Then** it returns `https://www.google.com/maps?entry=ml`

#### Scenario: Reconstruct from targetScheme + host + path + query

**Given** an `ExternalUrlInfo` parsed from `intent://www.google.com/maps?entry=ml#Intent;scheme=https;package=x;end` (no explicit fallback)
**When** `intentToWebUrl(info)` is called
**Then** it returns `https://www.google.com/maps?entry=ml`

#### Scenario: Non-http target scheme returns null

**Given** an `ExternalUrlInfo` with `targetScheme=zxing` and no `fallbackUrl`
**When** `intentToWebUrl(info)` is called
**Then** it returns `null`

#### Scenario: Non-http fallback URL returns null

**Given** an `ExternalUrlInfo` with `targetScheme=zxing` and `fallbackUrl=zxing://scan/`
**When** `intentToWebUrl(info)` is called
**Then** it returns `null`

#### Scenario: Non-intent input returns null

**Given** an `ExternalUrlInfo` with `scheme=tel`
**When** `intentToWebUrl(info)` is called
**Then** it returns `null`

#### Scenario: file:// fallback rejected

**Given** an `ExternalUrlInfo` with `targetScheme=file` and `fallbackUrl=file:///etc/passwd`
**When** `intentToWebUrl(info)` is called
**Then** it returns `null` (security: web origins must not steer the webview to local-file URLs)

---

### Requirement: EXT-003 - Silent Routing of Resolvable Intents

The webview SHALL silently route resolvable intent fallbacks through the standard same-domain / cross-domain navigation path, without showing the confirmation dialog.

#### Scenario: Same-domain intent fallback loads in current webview

**Given** the current site is `https://www.google.com/maps`
**And** the webview intercepts `intent://www.google.com/maps?entry=ml#Intent;scheme=https;…;S.browser_fallback_url=https%3A%2F%2Fwww.google.com%2Fmaps%3Fentry%3Dml;end`
**When** `shouldOverrideUrlLoading` resolves the intent to `https://www.google.com/maps?entry=ml`
**Then** the existing `shouldOverrideUrlLoading` callback returns `true` for the same-domain URL
**And** the webview calls `controller.loadUrl(https://www.google.com/maps?entry=ml)`
**And** no confirmation dialog is shown
**And** the original `intent://` navigation is `CANCEL`led

#### Scenario: Cross-domain intent fallback opens nested webview

**Given** the current site is `https://example.com`
**And** the webview intercepts `intent://www.google.com/maps#Intent;scheme=https;S.browser_fallback_url=https%3A%2F%2Fwww.google.com%2Fmaps;end`
**When** `shouldOverrideUrlLoading` resolves the intent to `https://www.google.com/maps`
**Then** the existing callback decides cross-domain → `blockOpenNested` → `launchUrlFunc(https://www.google.com/maps, …)` opens a nested `InAppWebViewScreen`
**And** the callback returns `false`, so the webview does NOT also call `loadUrl`
**And** no confirmation dialog is shown
**And** the original `intent://` navigation is `CANCEL`led

#### Scenario: target=_blank intent routes the same way

**Given** the user clicks `<a target="_blank" href="intent://…;S.browser_fallback_url=https://example.com;end">`
**When** `onCreateWindow` parses the intent and resolves it to `https://example.com`
**Then** the same routing applies: same-domain → `controller.loadUrl`; cross-domain → nested webview; no prompt

#### Scenario: Android onReceivedError path

**Given** an Android navigation to `intent://…;S.browser_fallback_url=https://example.com;end` skips `shouldOverrideUrlLoading` and surfaces in `onReceivedError`
**When** the suppression cache is cold
**Then** `onReceivedError` resolves the intent, marks the suppression entry, and posts a microtask that loads the resolved URL via the standard callback path

---

### Requirement: EXT-004 - Prompt Path Preserved for Unresolvable Intents

When `intentToWebUrl` returns `null`, the webview SHALL fall through to the existing `config.onExternalSchemeUrl` callback so the host can show the confirmation dialog and let the user pick an action.

#### Scenario: Scanner intent prompts the user

**Given** the webview intercepts `intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end`
**When** `intentToWebUrl` returns `null`
**Then** the webview calls `config.onExternalSchemeUrl(url, info)`
**And** the host shows the Cancel / Open in browser / Open in app dialog
**And** the original navigation is `CANCEL`led

#### Scenario: tel:/mailto:/custom schemes still prompt

**Given** the webview intercepts `tel:+14155551234`
**When** `ExternalUrlParser.parse` returns a non-intent `ExternalUrlInfo`
**Then** the webview skips the intent-resolve branch and calls `config.onExternalSchemeUrl(url, info)`
**And** the existing dialog is shown

---

### Requirement: EXT-005 - "Open in Browser" Loads in This Webview

The "Open in browser" choice in the confirmation dialog SHALL load the cleaned fallback URL inside the WebSpace webview that originated the navigation, not via `url_launcher`.

#### Scenario: Loads in the originating webview

**Given** the user is on a tel:/custom-scheme prompt with a non-empty cleaned fallback URL
**And** `confirmAndLaunchExternalUrl` was called with a non-null `loadInWebView` controller
**When** the user picks "Open in browser"
**Then** `loadInWebView.loadUrl(cleanedFallback)` is invoked
**And** `url_launcher.launchUrl` is NOT invoked
**And** the suppression cache is marked so the next identical fire is silenced

#### Scenario: Falls back to external launch when no controller available

**Given** `confirmAndLaunchExternalUrl` was called with `loadInWebView == null`
**Or** the in-app `loadUrl` call throws
**When** the user picks "Open in browser"
**Then** `_launchExternally(cleanedFallback, label: 'browser')` is invoked
**And** url_launcher hands the URL to the system default browser

---

### Requirement: EXT-006 - ClearURLs Stripping Survives Resolution

Tracking parameters SHALL be stripped from intent fallback URLs before they leave the app or load in the webview.

#### Scenario: Resolved fallback runs through ClearURLs

**Given** ClearURLs rules are loaded
**And** the resolved intent fallback is `https://www.google.com/maps?entry=ml&utm_campaign=ml-ardi-wv`
**When** `controller.loadUrl(resolved)` triggers a fresh `shouldOverrideUrlLoading` for the http(s) URL
**Then** the ClearURLs branch in `shouldOverrideUrlLoading` rewrites the URL to `https://www.google.com/maps?entry=ml`
**And** the webview loads the cleaned URL

#### Scenario: Confirmation-dialog path also strips tracking

**Given** an unresolvable intent (no http fallback) still hits the prompt
**When** `confirmAndLaunchExternalUrl` builds the dialog
**Then** `_stripTrackingFromIntent` rewrites both the toplevel query and the embedded `S.browser_fallback_url` extra
**And** the dialog displays the cleaned URLs to the user

---

### Requirement: EXT-007 - Suppression Loop Guard

After a navigation resolves through the silent intent path or the user makes a choice in the dialog, the system SHALL mark `ExternalUrlSuppressor` so a script-driven re-fire of the same intent does not re-trigger work or re-prompt the user.

#### Scenario: onReceivedError marks suppression on silent route

**Given** `onReceivedError` resolved an intent silently
**When** the page's JS re-fires the same intent moments later
**Then** the suppression cache returns true for the same intent key
**And** the second fire short-circuits to about:blank rather than re-loading the fallback

#### Scenario: Dialog choices mark suppression

**Given** the user picks Cancel / Open in browser / Open in app in the dialog
**Then** `ExternalUrlSuppressor.mark(info)` is called for that info
**And** a re-fire within the suppression window is silenced

---

## Data Models

### `ExternalUrlInfo`

```dart
class ExternalUrlInfo {
  final String url;          // raw URL string
  final String scheme;       // lowercase scheme (intent, tel, mailto, …)
  final String? host;        // intent target host or URI host
  final String? package;     // ;package= extra (intent only)
  final String? fallbackUrl; // S.browser_fallback_url extra (intent only)
  final String? targetScheme;// ;scheme= extra (intent only)
}
```

### Intent fragment grammar

```
intent://HOST/PATH?QUERY#Intent;scheme=...;package=...;S.browser_fallback_url=...;end
```

Extras live in the URL fragment, `;`-separated. `S.` prefix marks string extras per the [Chrome intent scheme spec](https://developer.chrome.com/docs/multidevice/android/intents).

---

## Files

### Modified

- `lib/services/external_url_engine.dart` — added `ExternalUrlParser.intentToWebUrl`.
- `lib/services/webview.dart` — intent-resolve branch in `shouldOverrideUrlLoading`, `onCreateWindow`, `onReceivedError`.
- `lib/widgets/external_url_prompt.dart` — `confirmAndLaunchExternalUrl` accepts `loadInWebView`; "Open in browser" loads inside the webview.
- `lib/main.dart` and `lib/screens/inappbrowser.dart` — pass the active controller as `loadInWebView` when invoking the prompt.

### Test coverage

- `test/external_url_engine_test.dart` — unit tests for `ExternalUrlParser.intentToWebUrl` covering: non-intent input, explicit fallback, scheme+host+path+query reconstruction, non-http target scheme, non-http fallback.

---

## Testing

### Manual: Google Maps no longer prompts

1. Add `https://maps.google.com` as a WebSpace site (Android device, no Google Maps app installed is fine).
2. Open the site, navigate within Maps.
3. The intent-confirmation dialog MUST NOT appear.
4. Navigation stays inside the webview throughout.

### Manual: Scanner intent still prompts

1. Visit a page that fires `intent://scan/#Intent;scheme=zxing;…;end` (e.g. a QR-code embed).
2. The dialog MUST appear with Cancel / Open in browser (disabled, no fallback) / Open in app buttons.
3. "Open in app" launches the scanner if installed; otherwise the snackbar reports "no app available".

### Manual: tel: / mailto: still prompt

1. Tap a `tel:+1…` link.
2. The dialog MUST appear.
3. "Open in app" launches the dialer.

### Manual: "Open in browser" loads in the webview

1. Visit a page that fires a custom-scheme intent with an http fallback (or any intent the silent path doesn't catch).
2. Pick "Open in browser".
3. The fallback URL MUST load inside the same webview (or open in a nested screen if cross-domain), NOT in Chrome/Safari.

### Automated

`fvm flutter test test/external_url_engine_test.dart`

---

## Related

- [`navigation`](../navigation/spec.md) — main navigation orchestration; `shouldOverrideUrlLoading` is the entry point this spec hooks into.
- [`nested-url-blocking`](../nested-url-blocking/spec.md) — the same-domain / cross-domain decision used to route resolved intents.
- [`clearurls`](../clearurls/spec.md) — tracking-parameter stripping that intent fallbacks inherit.
- [`ios-universal-link-bypass`](../ios-universal-link-bypass/spec.md) — sibling concern: keeping iOS user-tap navigations inside the webview when AASA would otherwise route them to a native app.

## Future Work

- A per-site **"never prompt for external schemes"** toggle for users who want even tel:/mailto:/custom-scheme links suppressed.
- A long-press affordance to launch the native app deliberately (currently the only escape hatch is the OS-level "open with" menu).
- Suppression cache persistence across app restarts.
