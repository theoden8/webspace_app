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
   - `<meta name="viewport">` → rewritten to `width=1366, initial-scale=1.0`,
     both for existing tags and via a `MutationObserver` for tags added
     later. The width must clear the widest "desktop" breakpoint a
     mainstream site uses; Bluesky's `useWebMediaQueries` gates
     `isDesktop` on `(min-width: 1300px)` and treats 800-1299 as
     tablet, so a smaller value ships the tablet layout. iOS WKWebView
     re-evaluates the meta on mutation; **Android Chromium WebView does
     NOT** — the rewrite only changes the attribute string, so on
     Android the next bullet (Android-only spoof) is what actually
     shifts the JS-visible layout viewport.
   - **Android-only** (gated on `Platform.isAndroid` in
     `webview.dart`, plumbed through `buildDesktopModeShim(...,
     spoofLayoutViewport: true)`): pin `window.innerWidth` /
     `outerWidth` / `innerHeight` / `outerHeight` to `1366` / `1366` /
     `768` / `768`, and extend the `matchMedia` wrapper so width-based
     queries (`(min-width: …)` / `(max-width: …)` / `(min-device-width:
     …)` / `(max-device-width: …)`, including those combined with
     `only screen and …`) are answered against the spoofed `1366`
     viewport. Width queries that mix in clauses we don't recognise
     (orientation, color, hover, etc.) fall through to the real CSS
     engine, so we never lie about queries we can't evaluate.
   - **NOT spoofed**: `window.devicePixelRatio`, `screen.width`. DPR is
     orthogonal to layout (real retina desktops report dpr ≥ 2);
     `screen.*` belongs to the anti-fingerprinting shim's domain and
     would conflict if we touched it here.

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

### Requirement: DM-003 — Layout viewport spoof on Android

The system SHALL pin `window.innerWidth` / `outerWidth` / `innerHeight`
/ `outerHeight` and forge width-based `matchMedia` queries against a
synthetic `1366×768` viewport when the desktop-mode shim runs on
Android, and SHALL NOT do so on any other host platform.

Android Chromium WebView does not re-run viewport calculation when
`<meta name="viewport">` content is mutated post-parse, so the
MutationObserver rewrite changes the attribute string without changing
`window.innerWidth` or CSS width media-query evaluation. React Native
Web sites (Bluesky and similar) read `window.innerWidth` and
`matchMedia('(min-width: …)')` at boot to pick a layout, so without
this requirement they ship the mobile branch despite the desktop UA.

The shim builder accepts `spoofLayoutViewport: true` (passed from
`webview.dart` when `Platform.isAndroid`); the call site MUST pass
`false` on iOS / macOS / Linux, where the platform either re-evaluates
the meta on mutation or synthesizes a desktop viewport at the WebKit
level via `preferredContentMode = .desktop`.

When `spoofLayoutViewport == true`:

1. `window.innerWidth` and `window.outerWidth` are pinned to `1366`.
2. `window.innerHeight` and `window.outerHeight` are pinned to `768`.
3. The `matchMedia` wrapper additionally answers `(min-width: N)` /
   `(max-width: N)` / `(min-device-width: N)` / `(max-device-width:
   N)` queries against the same `1366` value, including queries
   prefixed by `only screen and …` and queries combining multiple
   width clauses via `and`.
4. Queries that mix in clauses we don't recognise (e.g.
   `(orientation: portrait)`, `(prefers-color-scheme: dark)`, raw
   `not`) fall through to the real `matchMedia` so we never forge an
   answer for a query we can't fully evaluate.

#### Scenario: Android variant pins window.innerWidth to 1366

**Given** the desktop-mode shim runs on Android (`spoofLayoutViewport=true`)
**When** the page reads `window.innerWidth`
**Then** the value is `1366`
**And** `window.outerWidth` is `1366`
**And** `window.innerHeight` is `768`
**And** `window.outerHeight` is `768`

#### Scenario: Bluesky's desktop breakpoint matches on Android

**Given** the desktop-mode shim runs on Android
**When** the page evaluates `matchMedia('(min-width: 1300px)').matches`
**Then** the value is `true` (1366 ≥ 1300)
**And** `matchMedia('only screen and (max-width: 1300px)').matches` is `false`
**And** `matchMedia('(min-width: 800px) and (max-width: 1299px)').matches` is `false`

#### Scenario: Non-width queries fall through to native

**Given** the desktop-mode shim runs on Android
**When** the page evaluates `matchMedia('(prefers-color-scheme: dark)')`
**Then** the wrapper does NOT synthesize an answer
**And** the result comes from the real CSS engine

#### Scenario: Default build does not pin innerWidth

**Given** the desktop-mode shim runs on iOS / macOS / Linux (`spoofLayoutViewport=false`)
**When** the page reads `window.innerWidth`
**Then** the value comes from the underlying platform — we MUST NOT
override it, since iOS WKWebView in `preferredContentMode=.desktop`
already reports a desktop-shaped viewport.

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
| `lib/services/webview.dart` | `createWebView`: injects shim, sets `preferredContentMode`, and assigns `userAgentMetadata` from the per-site UA |
| `test/user_agent_classifier_test.dart` | Coverage for the inference helpers |
| `test/desktop_mode_shim_test.dart` | Coverage for the JS shim source generation |
| `test/user_agent_metadata_builder_test.dart` | Coverage for the UA-CH override (mobile flag, platform, brand list, GREASE entry, wire shape) |
