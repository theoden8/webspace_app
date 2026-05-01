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
   - `<meta name="viewport">` → rewritten to `width=1280, initial-scale=1.0`,
     both for existing tags and via a `MutationObserver` for tags added
     later. This is what makes width-based responsive CSS pick the
     desktop layout, since `useWideViewPort` alone respects whatever
     viewport meta the page ships.
   - **NOT spoofed**: `window.devicePixelRatio`, `window.innerWidth`,
     `screen.width`. DPR is orthogonal to layout (real retina desktops
     report dpr ≥ 2); the width properties are backed by native layout
     measurements, and the meta-viewport rewrite handles width-based CSS
     directly.

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
**Then** the meta element's `content` attribute reads `width=1280, initial-scale=1.0` before layout runs
**And** any later-injected viewport meta is also rewritten

#### Scenario: Re-entrance guard prevents matchMedia recursion

**Given** the shim has already executed in a frame
**When** `initialUserScripts` is re-evaluated for the same frame
**Then** the second invocation observes `window.__ws_desktop_shim__ === true` and returns
**And** the existing `matchMedia` wrapper is not wrapped a second time

---

### Requirement: DM-003 — Sec-CH-UA-* tracks the spoofed UA on Android

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
| `lib/services/webview.dart` | `createWebView`: injects shim, sets `preferredContentMode`, and assigns `userAgentMetadata` from the per-site UA |
| `test/user_agent_classifier_test.dart` | Coverage for the inference helpers |
| `test/desktop_mode_shim_test.dart` | Coverage for the JS shim source generation |
| `test/user_agent_metadata_builder_test.dart` | Coverage for the UA-CH override (mobile flag, platform, brand list, GREASE entry, wire shape) |
