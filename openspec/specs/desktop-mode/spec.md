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

### Requirement: DM-004 — Generated UAs track the current Firefox version

The system SHALL render generated User-Agents (the randomize button and the
canonical desktop UA getters) at the Firefox version baked into the build
(`kDefaultFirefoxMajorVersion`), and SHALL allow the user to refresh that
version on demand by scraping the current release version from Firefox
source. The scrape is performed **only** in response to an explicit user
gesture (an "Update Firefox version" control in app settings) — never
automatically, on startup or otherwise — so the app issues no network
request the user did not initiate (an F-Droid inclusion requirement). The
result is cached and persisted; the cached version only moves forward — a
scraped value below the bundled floor is ignored, so an app upgrade never
regresses the UA.

The scrape routes through the app-global outbound proxy and fails closed
(no direct fallback) when the proxy cannot be honored. Loading the cached
version at startup performs no network I/O.

Sources, tried in order:
1. `raw.githubusercontent.com/mozilla-firefox/firefox/release/browser/config/version_display.txt`
   — the canonical source file (user-facing release version). Firefox
   development moved from hg.mozilla.org to GitHub in 2025; the old
   hg raw-file URL is dead.
2. `product-details.mozilla.org/1.0/firefox_versions.json`
   (`LATEST_FIREFOX_VERSION`) — Mozilla's machine-readable fallback.

Only the major version is used; Firefox freezes the UA minor at `.0`
regardless of point release.

The randomize set the version feeds renders realistic per-platform Firefox
shapes: desktop (`X11; Linux x86_64` / `Macintosh; Intel Mac OS X 10.15` /
`Windows NT 10.0; Win64; x64`, Gecko trail frozen at `20100101`),
Firefox-for-Android (pinned current `Android <major>; Mobile`, Gecko trail
equal to the version), and Firefox-for-iOS (WebKit/Safari-shaped with an
`FxiOS/<version>` marker ending in `Mobile/15E148 Safari/604.1`, since iOS
mandates WebKit). Every token mirrors the upstream construction in gecko's
`nsHttpHandler.cpp` and firefox-ios's `UserAgent.swift`; the Node test
`test/js/firefox_ua_upstream.test.js` scrapes both sources and fails when
our constants drift from what real Firefox sends. No generated UA may ever
combine an Apple-mobile platform token with the Gecko desktop grammar —
that combination exists in no real browser and marks the app as an
embedded webview (x.com bounces it to `x-safari-https://`).

#### Scenario: No network request without an explicit user gesture

**Given** the app starts up
**When** initialization runs
**Then** the cached Firefox version loads from disk with no network I/O
**And** no scrape of Firefox source is performed until the user taps the
"Update Firefox version" control in app settings

#### Scenario: Newer version scraped → adopted and persisted

**Given** the bundled default major version is `N`
**And** the user taps "Update Firefox version"
**And** the source file reports `M.0` with `M > N`
**When** the version is refreshed
**Then** generated UAs render `Firefox/M.0` and `rv:M.0`
**And** the value is persisted for the next launch

#### Scenario: Source file unreachable → product-details fallback

**Given** the source file request fails (non-200 or network error)
**And** product-details reports `LATEST_FIREFOX_VERSION`
**When** the version is refreshed
**Then** the product-details version is adopted

#### Scenario: Offline / older / garbage → bundled floor holds

**Given** both sources fail, or report a version older than the bundled
floor, or return a non-numeric / out-of-range body
**When** the version is refreshed
**Then** generated UAs keep rendering the bundled `kDefaultFirefoxMajorVersion`

---

### Requirement: DM-005 — Generated UAs persist as presets, not strings

A per-site UA that came from the generator SHALL be persisted as a
`uaPreset` (`WebViewModel.uaPreset`, one of
`firefoxLinux|firefoxWindows|firefoxMacos|firefoxAndroid|firefoxIos`) and
re-rendered at webview-creation time (`effectiveUserAgent`) from the
current builders and Firefox version, so builder fixes and version
refreshes apply retroactively to every site. A persisted string is a
derivative of the builders + version; freezing it is how UAs rot until
sites break on them. Free-text custom UAs (`uaPreset == null`) SHALL pass
through verbatim and never be rewritten.

On load (`fromJson`) and on save from site settings, a stored string that
exactly matches a shape any historical generator emitted — including the
pre-#410 iPhone-token-in-Gecko-grammar hybrid, the `10_15_7` macOS token,
the `Safari/605.1.15` FxiOS tail, and the desktop-trail Android shape —
SHALL be assigned its preset (idempotent migration). Exact-shape matches
only: `rv:`/`Firefox/` version mismatches and real-browser strings (Mobile
Safari, Chrome, Mozilla's Gecko-on-iOS whose trail equals the version)
MUST stay custom.

#### Scenario: Legacy broken UA heals on load

**Given** a site persisted `Mozilla/5.0 (iPhone; CPU iPhone OS 15_7_3 like
Mac OS X; rv:147.0) Gecko/20100101 Firefox/147.0` by an old build
**When** the site is rehydrated from JSON
**Then** `uaPreset` becomes `firefoxIos`
**And** the webview is created with the current FxiOS UA, not the stored string

#### Scenario: Version-stale generated UA re-renders current

**Given** a site persisted a Linux Firefox UA rendered at version 120
**When** the site is rehydrated and its webview created
**Then** the UA sent carries the current Firefox version, not 120

#### Scenario: Custom UA is never rewritten

**Given** a site whose UA the user typed by hand (matches no generated shape)
**When** the site is rehydrated
**Then** `uaPreset` is null and the exact string is sent unchanged

#### Scenario: Randomize round-trips through the preset

**Given** the user taps randomize and saves site settings
**When** the generated text is stored
**Then** `setUserAgent` recognizes the shape and re-attaches the preset
**And** a later version refresh changes what the webview sends without
re-visiting site settings

---

## Files

| File | Role |
|------|------|
| `lib/services/user_agent_classifier.dart` | `isDesktopUserAgent`, `inferDesktopUaPlatform`, `navigatorPlatformFor`, `buildFirefoxUserAgent` / `buildFirefoxAndroidUserAgent` / `buildFirefoxIosUserAgent`, canonical Firefox desktop UA constants + `kDefaultFirefoxMajorVersion` |
| `lib/services/firefox_user_agent_service.dart` | Scrapes (user-initiated only) + caches the current Firefox release version; renders generated UAs at that version |
| `lib/screens/app_settings.dart` | "Update Firefox version" control — the sole, explicit trigger for the scrape, with a hint explaining it is the only network access |
| `test/firefox_user_agent_service_test.dart` | Coverage for version parsing, UA rendering, and the scrape/cache/floor behavior |
| `lib/services/desktop_mode_shim.dart` | `buildDesktopModeShim(userAgent)` — JS source for AT_DOCUMENT_START injection |
| `lib/services/user_agent_metadata_builder.dart` | `buildUserAgentMetadata(userAgent)` — UA-CH override mapped 1:1 with the spoofed UA. Wired through to `WebSettingsCompat.setUserAgentMetadata` on Android via the fork's `InAppWebViewSettings.userAgentMetadata`. |
| `lib/services/webview.dart` | `createWebView`: injects shim, sets `preferredContentMode`, and assigns `userAgentMetadata` from the per-site UA |
| `test/user_agent_classifier_test.dart` | Coverage for the inference helpers |
| `test/desktop_mode_shim_test.dart` | Coverage for the JS shim source generation |
| `test/user_agent_metadata_builder_test.dart` | Coverage for the UA-CH override (mobile flag, platform, brand list, GREASE entry, wire shape) |
