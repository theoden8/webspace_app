# Desktop Mode Specification

## Purpose

Render a site with a desktop layout (UA, viewport, pointer / touch
semantics, `<meta name=viewport>` neutralized) when the user has set a
desktop-shaped User-Agent on it, and a mobile layout otherwise — without
requiring a separate per-site toggle.

## Status

- **Date**: 2026-04-28
- **Status**: Implemented

---

## Problem Statement

A previous iteration of this feature shipped an explicit per-site
`desktopMode` toggle (`bool` then enum `{ off, linux, macos, windows }`)
alongside the existing per-site User-Agent field. That created two ways
to express the same intent: a user who set a desktop UA still had to flip
a separate switch for the webview to actually render desktop, and the
two could disagree (mobile UA + toggle on, or vice versa) with no
defensible behavior. PR #235 was reverted upstream after that complexity
caused user-visible bugs.

The current design **infers** desktop mode from the per-site User-Agent
string. The user's only knob is the UA field (already exposed in site
settings, with a randomize button cycling through Firefox desktop and
mobile UAs). If the UA contains a mobile marker (`Android`, `iPhone`,
`iPad`, `iPod`, `Mobile`, `BlackBerry`, `Windows Phone`, `Opera Mini`,
`webOS`, `Kindle`, case-insensitive), the site renders mobile. Otherwise
desktop. There is no separate toggle and no separate persisted field.

## What "desktop mode" actually does

When `isDesktopUserAgent(userAgent)` is true at webview-creation time:

1. **`InAppWebViewSettings.preferredContentMode = DESKTOP`.** Triggers the
   plugin's `setDesktopMode(true)` path on Android (flips
   `useWideViewPort` + `loadWithOverviewMode` + zoom — the UA-rewriting
   side of that code becomes a no-op because our UA already has no
   `"Mobile"`/`"Android"` substrings) and `WKWebpagePreferences.preferredContentMode = .desktop`
   on iOS (synthesizes desktop UA + viewport at the WebKit level).
2. **JS shim injected at AT_DOCUMENT_START** (`lib/services/desktop_mode_shim.dart`).
   The shim patches the JS-side signals the WebView still emits despite
   the UA override:
   - `navigator.userAgentData` → `undefined`. Our spoofed UA is
     Firefox-shaped and Firefox does not implement Client Hints; sites
     feature-detecting the API by reading the property must see
     `undefined`, not a Chromium-WebView-populated mobile object.
   - `navigator.maxTouchPoints` → `0`.
   - `navigator.platform` → `"Linux x86_64"` / `"MacIntel"` / `"Win32"`,
     inferred from the UA via `inferDesktopUaPlatform`.
   - `'ontouchstart' in window` → `false` (property redefined as undefined).
   - `@media (pointer: fine)` / `(hover: hover)` and the `any-*` variants
     → forced match; `(pointer: coarse)` / `(hover: none)` → forced no-match.
     Other queries fall through to the real `matchMedia`.
   - `<meta name="viewport">` → rewritten to `width=1366, initial-scale=1.0`
     via a JS-side `MutationObserver` that catches both pre-existing
     and dynamically inserted viewport metas. iOS WKWebView re-evaluates
     the viewport on attribute mutation; Android Chromium WebView does
     NOT, which is why on Android we additionally rewrite the meta on
     the wire (see point 3). The width must clear the widest "desktop"
     breakpoint a mainstream site uses; Bluesky's `useWebMediaQueries`
     gates `isDesktop` on `(min-width: 1300px)` and treats 800-1299 as
     tablet, so a smaller value ships the tablet layout.
   - **NOT spoofed by the JS shim**: `window.devicePixelRatio`,
     `window.innerWidth`, `screen.width`. DPR is orthogonal to layout;
     the width properties are backed by native layout measurements
     which we move via the wire-level rewrite below.
3. **Android-only main-document rewrite, on the wire**, in the native
   `FastSubresourceInterceptor`
   ([`WebInterceptPlugin.kt`](../../../android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebInterceptPlugin.kt)).
   Android Chromium WebView does not recompute layout when the meta
   viewport is mutated post-parse, so the JS-side rewrite alone leaves
   `window.innerWidth` at the device's CSS width and React Native Web
   sites (Bluesky and similar) ship the mobile branch despite the
   desktop UA. To actually move the layout viewport, when a WebView
   is created with a desktop UA on Android, the Dart side passes
   `desktopMode: true` to `WebInterceptNative.attachToWebViews`, which
   plumbs through to `FastSubresourceInterceptor.isDesktopMode`. The
   interceptor then branches on `request.isForMainFrame` for `GET`
   `http(s)://…` requests: re-fetch via `HttpURLConnection` (forwarding
   the WebView's request headers — desktop UA, Sec-CH-UA-*, Cookie,
   Accept-Language — and back-stopping cookies from the global
   `CookieManager`), decompress gzip/deflate, decode the body with
   the upstream's `charset`, regex-rewrite every `<meta name=viewport>`
   to `width=1366, initial-scale=1.0`, and hand the modified bytes
   back as a `WebResourceResponse` so the WebView's HTML parser sees
   the desktop viewport at parse time. Sub-resource requests still go
   through the existing DNS/ABP/LocalCDN logic in the same handler,
   and any error path (non-HTML, non-2xx, decompression failure,
   network error) returns `null` so the WebView falls through to its
   own native fetch. iOS, macOS and Linux are unaffected.

A re-entrance guard (`window.__ws_desktop_shim__`) prevents the
`matchMedia` wrapper from wrapping itself when the plugin re-injects
`initialUserScripts` on per-frame loads.

## Requirements

### Requirement: DM-001 — Desktop mode is inferred from the User-Agent

The system SHALL classify a site as desktop iff its User-Agent string is
non-empty and does not contain any mobile marker substring (case-
insensitive): `android`, `iphone`, `ipad`, `ipod`, `mobile`,
`blackberry`, `windows phone`, `opera mini`, `webos`, `kindle`. There is
no separate persisted `desktopMode` field.

#### Scenario: Empty UA → mobile

**Given** a site with `userAgent = ""`
**When** the webview is created
**Then** `isDesktopUserAgent` returns `false`
**And** `preferredContentMode` is `RECOMMENDED`
**And** the desktop-mode shim is NOT injected

#### Scenario: Android Firefox UA → mobile

**Given** a site with `userAgent` containing `"Android"` and/or `"Mobile"`
**When** the webview is created
**Then** the site renders mobile

#### Scenario: Linux Firefox desktop UA → desktop

**Given** a site with `userAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:147.0) Gecko/20100101 Firefox/147.0"`
**When** the webview is created
**Then** `isDesktopUserAgent` returns `true`
**And** `preferredContentMode` is `DESKTOP`
**And** the desktop-mode shim is injected at `AT_DOCUMENT_START` for every frame
**And** `navigator.platform` reads `"Linux x86_64"` from page JS

#### Scenario: Mid-life UA change → webview recreated

The UA classification is fixed at webview construction — the platform's
`InAppWebViewSettings.userAgent` and `initialUserScripts` cannot be
swapped in place after creation. Calling `controller.loadUrl` alone
reloads the *page* but reuses the existing controller's baked-in user-
agent and scripts, so a desktop UA set after the webview was created
would silently keep emitting the mobile fingerprint.

**Given** a site whose webview was created with a mobile or empty UA
**When** the user updates the per-site UA to a desktop-shaped string
**And** `SettingsScreen` saves and fires `onSettingsSaved`
**Then** the host disposes the existing webview
**And** the next render constructs a fresh webview using the updated UA
**And** `preferredContentMode` is `DESKTOP`
**And** the desktop-mode shim is injected at `AT_DOCUMENT_START` for the
new webview

---

### Requirement: DM-002 — JS-side desktop fingerprint

When the shim is injected, the page MUST observe a coherent desktop
fingerprint (see "What desktop mode actually does" above), not the
underlying mobile WebView's signals.

#### Scenario: Touch / pointer signals report desktop

**Given** a site with a desktop UA is loaded
**When** the page reads `navigator.maxTouchPoints`
**Then** the value is `0`
**And** `'ontouchstart' in window` is `false`
**And** `matchMedia('(pointer: fine)').matches` is `true`
**And** `matchMedia('(hover: hover)').matches` is `true`
**And** `matchMedia('(pointer: coarse)').matches` is `false`

#### Scenario: Client Hints API reads as Firefox-style

**Given** a site with a desktop UA is loaded
**When** the page reads `navigator.userAgentData`
**Then** the value is `undefined`

#### Scenario: Viewport meta is rewritten to desktop width

**Given** a page ships `<meta name="viewport" content="width=device-width, initial-scale=1">`
**And** the site UA is desktop-shaped
**When** the document is parsed
**Then** the meta element's `content` attribute reads `width=1366, initial-scale=1.0` before layout runs
**And** any later-injected viewport meta is also rewritten

#### Scenario: Re-entrance guard prevents matchMedia recursion

**Given** the shim has already executed in a frame
**When** `initialUserScripts` is re-evaluated for the same frame
**Then** the second invocation observes `window.__ws_desktop_shim__ === true` and returns
**And** the existing `matchMedia` wrapper is not wrapped a second time

---

### Requirement: DM-003 — Layout viewport rewritten on the wire (Android)

The system SHALL intercept main-document HTTP responses on Android in
the native `FastSubresourceInterceptor` when the per-site UA is
desktop-shaped, replace every `<meta name="viewport">` in the HTML
body with a synthetic `width=1366, initial-scale=1.0`, and return the
modified response so the WebView's HTML parser sees the desktop
viewport at parse time. Sub-resources (handled by the same interceptor
via the existing DNS/ABP/LocalCDN paths), non-main-frame requests,
non-HTML responses, non-GET navigations, non-`http(s)` schemes, and any
upstream error MUST fall through to the WebView's native fetch (the
handler returns `null`). Other host platforms (iOS, macOS, Linux) MUST
NOT enable this interception — iOS WKWebView synthesizes a desktop
viewport via `WKWebpagePreferences.preferredContentMode = .desktop`,
and the desktop platforms render at their native viewport.

The flag flows from Dart at WebView attach time:
`WebInterceptNative.attachToWebViews(siteId: …, desktopMode: …)` →
`WebInterceptPlugin.attachToAllWebViews(newSiteId, desktopMode)` →
`FastSubresourceInterceptor(isDesktopMode = desktopMode, …)`. Each
WebView gets its own interceptor instance, so changing the UA mid-life
follows the existing "dispose + recreate" path in `_WebSpacePageState`
(see DM-001's "Mid-life UA change → webview recreated" scenario).

#### Scenario: Bluesky-style HTML rewritten on Android

**Given** a site with a desktop UA navigates to `https://bsky.app/`
on Android
**When** the native `FastSubresourceInterceptor.checkUrl` is invoked
with `isForMainFrame == true`, `method == "GET"`, the upstream
returns `Content-Type: text/html`, and `isDesktopMode == true`
**Then** the handler re-fetches the page through `HttpURLConnection`
(forwarding the WebView's request headers and back-stopping cookies
from `CookieManager`)
**And** every `<meta name="viewport" ...>` in the response body is
replaced with `<meta name="viewport" content="width=1366,
initial-scale=1.0">`
**And** the modified bytes are returned via `WebResourceResponse`
with the upstream `statusCode`, `reasonPhrase`, and `Set-Cookie` /
`Cache-Control` / `Content-Security-Policy` headers preserved
**And** `Content-Length`, `Content-Encoding`, `Transfer-Encoding`,
and the `Content-Type` header are dropped because the body is now
plain decompressed bytes whose length differs and the new
`text/html` mime + charset are passed via the response constructor
**And** any `Set-Cookie` response headers are re-applied to
`CookieManager.getInstance().setCookie(url, ...)` so the WebView's
cookie jar tracks logins through the rewrite

#### Scenario: Page without a viewport meta gets one injected

**Given** a main-document HTML response that does NOT ship a
`<meta name="viewport">`
**When** the rewriter processes the body
**Then** a `<meta name="viewport" content="width=1366,
initial-scale=1.0">` is injected immediately after `<head>`
**And** the rest of `<head>`'s contents are preserved verbatim

#### Scenario: Non-HTML / non-2xx / non-GET / sub-resource → fall through

**Given** any of: `request.isForMainFrame == false`,
`request.method != "GET"`, scheme not in `{http, https}`, response
`Content-Type` is not `text/html`/`application/xhtml+xml`, or the
response status is outside `[200, 400)`
**When** `tryRewriteMainDocViewport` is invoked
**Then** it returns `null` and `checkUrl` continues with its existing
sub-resource logic (DNS / ABP / LocalCDN), or — for main-frame
requests — returns `null` so the WebView fetches natively

#### Scenario: Upstream error → fall through

**Given** the `HttpURLConnection.connect()` or read throws
(timeout, DNS error, TLS error, IOException)
**When** the rewriter catches the error
**Then** it logs a `WebIntercept` entry with the URL and exception
**And** returns `null` so the WebView retries via its native fetch
and the user sees the platform-native error page

#### Scenario: Charset preserved on rewrite

**Given** an HTML response with `Content-Type: text/html;
charset=iso-8859-1` whose body contains non-ASCII bytes
**When** the rewriter decodes via `Charset.forName("iso-8859-1")`,
modifies the viewport meta, and re-encodes
**Then** the non-ASCII bytes survive the round-trip unchanged
**And** the response's `contentEncoding` (the `WebResourceResponse`
charset field) reflects `iso-8859-1`

#### Scenario: Mobile UA → interceptor disabled

**Given** a per-site UA WITHOUT a desktop marker (e.g., contains
`Mobile`, `Android`, `iPhone`)
**When** the WebView is created on Android
**Then** Dart calls `WebInterceptNative.attachToWebViews(...,
desktopMode: false)`
**And** `FastSubresourceInterceptor.isDesktopMode == false`
**And** main-doc requests fall through directly to the WebView's
native fetch with no Dart-or-Kotlin-side rewrite

---

### Requirement: DM-004 — Sec-CH-UA-* tracks the spoofed UA on Android

The system SHALL override the `Sec-CH-UA`, `Sec-CH-UA-Mobile`, and
`Sec-CH-UA-Platform` HTTP request headers and the
`navigator.userAgentData` JS surface so they stay consistent with the
per-site User-Agent string. Chromium WebView emits these values from a
**User-Agent metadata object** independent of the UA string; without an
override a desktop UA leaks `Sec-CH-UA-Mobile: ?1` and
`Sec-CH-UA-Platform: "Android"`, and sites that gate on UA-CH rather
than the UA string (DuckDuckGo, anti-bot vendors) keep serving mobile
layouts and observe a contradictory fingerprint.

The override is wired through
[`InAppWebViewSettings.userAgentMetadata`] →
`androidx.webkit.WebSettingsCompat.setUserAgentMetadata` (gated on
`WebViewFeature.USER_AGENT_METADATA`), and applied for every non-empty
per-site UA — desktop or mobile — at webview-creation time. On iOS /
macOS / Linux there is no equivalent native API; the field is
serialized but the platform plugin silently drops it.

#### Scenario: Desktop UA → Sec-CH-UA-Mobile reads `?0`

**Given** a site with `userAgent = "Mozilla/5.0 (X11; Linux x86_64; rv:147.0) Gecko/20100101 Firefox/147.0"`
**When** the webview is created on Android
**Then** `InAppWebViewSettings.userAgentMetadata.mobile` is `false`
**And** `userAgentMetadata.platform` is `"Linux"`

#### Scenario: Mobile UA → Sec-CH-UA-Mobile reads `?1`

**Given** a site with `userAgent = "Mozilla/5.0 (Android 16; Mobile; rv:147.0) Gecko/20100101 Firefox/147.0"`
**When** the webview is created on Android
**Then** `userAgentMetadata.mobile` is `true`
**And** `userAgentMetadata.platform` is `"Android"`

#### Scenario: Brand list matches the UA family

**Given** a site with a Firefox-shaped UA
**When** the webview is created on Android
**Then** `userAgentMetadata.brandVersionList` carries a Firefox brand
entry whose `majorVersion` equals the UA's `Firefox/N` major
**And** the list is prefixed with the W3C-recommended GREASE entry
(`brand: "Not.A/Brand"`, `majorVersion: "99"`)

**Given** a site with a Chrome-shaped UA
**When** the webview is created on Android
**Then** the brand list carries `"Chromium"` and `"Google Chrome"`
entries with the parsed version
**And** is prefixed with the GREASE entry

#### Scenario: Empty UA → no override

**Given** a site with `userAgent = ""`
**When** the webview is created on Android
**Then** `userAgentMetadata` is `null`
**And** the platform default UA-CH metadata reaches the wire — we do not
manufacture a fake brand list when the user has not chosen a UA.

---

## Files

| File | Role |
|------|------|
| `lib/services/user_agent_classifier.dart` | `isDesktopUserAgent`, `inferDesktopUaPlatform`, `navigatorPlatformFor`, canonical Firefox desktop UA constants |
| `lib/services/desktop_mode_shim.dart` | `buildDesktopModeShim(userAgent)` — JS source for AT_DOCUMENT_START injection |
| `lib/services/user_agent_metadata_builder.dart` | `buildUserAgentMetadata(userAgent)` — UA-CH override mapped 1:1 with the spoofed UA. Wired through to `WebSettingsCompat.setUserAgentMetadata` on Android via the fork's `InAppWebViewSettings.userAgentMetadata`. |
| `android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebInterceptPlugin.kt` | `FastSubresourceInterceptor.tryRewriteMainDocViewport` — Android-only main-document re-fetch + viewport meta rewrite, plumbed via `attachToWebViews(desktopMode = true)`. `Companion.rewriteViewportMeta(html)` is a pure-Kotlin helper for the regex (verified via standalone Kotlin checks against Bluesky-shaped, attribute-order-swapped, multi-meta, and missing-`<head>` inputs). |
| `lib/services/web_intercept_native.dart` | Dart bridge: `attachToWebViews(siteId, desktopMode)` |
| `lib/services/webview.dart` | `createWebView`: injects shim, sets `preferredContentMode`, assigns `userAgentMetadata`, and on Android passes `desktopMode = isDesktopUserAgent(...)` through `WebInterceptNative.attachToWebViews` |
| `test/user_agent_classifier_test.dart` | Coverage for the inference helpers |
| `test/desktop_mode_shim_test.dart` | Coverage for the JS shim source generation |
| `test/user_agent_metadata_builder_test.dart` | Coverage for the UA-CH override (mobile flag, platform, brand list, GREASE entry, wire shape) |
