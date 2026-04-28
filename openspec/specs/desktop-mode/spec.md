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

### Requirement: DM-003 — Backup migration from legacy desktopMode field

`WebViewModel.fromJson` SHALL apply the migration table below when an
imported site has the legacy per-site `desktopMode` field (which earlier
branches persisted, first as a `bool`, later as a string enum
`"off"` / `"linux"` / `"macos"` / `"windows"`) AND its `userAgent` is
empty. The migration populates `userAgent` so the user's intended
desktop / mobile behavior is preserved on import without requiring them
to manually re-edit the UA.

| Legacy `desktopMode` value | Migrated `userAgent` |
|---|---|
| `true` (bool) | Firefox Linux desktop UA |
| `false` (bool) | empty (mobile) |
| `"linux"` | Firefox Linux desktop UA |
| `"macos"` | Firefox macOS desktop UA |
| `"windows"` | Firefox Windows desktop UA |
| `"off"` | empty (mobile) |
| absent / unknown | empty (no migration) |

If the imported `userAgent` is non-empty, it wins — the user's explicit
custom UA is preserved regardless of the legacy `desktopMode` value.

The legacy `desktopMode` field is NOT preserved on re-export. The current
model has no such field; it is consumed at import time and discarded.

#### Scenario: Old bool=true backup with no custom UA

**Given** a backup contains `"desktopMode": true` and `"userAgent": ""`
**When** the user imports the backup
**Then** the restored site has `userAgent == firefoxLinuxDesktopUserAgent`
**And** `isDesktopUserAgent(userAgent)` is `true`

#### Scenario: Old enum=macos backup migrates to macOS desktop UA

**Given** a backup contains `"desktopMode": "macos"` and `"userAgent": ""`
**When** the user imports the backup
**Then** the restored site has `userAgent == firefoxMacosDesktopUserAgent`

#### Scenario: User's custom UA wins over migration

**Given** a backup contains `"desktopMode": "macos"` and `"userAgent": "MyCustom/1.0"`
**When** the user imports the backup
**Then** the restored site has `userAgent == "MyCustom/1.0"`

---

## Known limitation: `Sec-CH-UA-*` HTTP headers

The `Sec-CH-UA`, `Sec-CH-UA-Mobile`, and `Sec-CH-UA-Platform` HTTP
request headers are emitted by the native Chromium WebView (Android) /
WebKit (iOS) from a **User-Agent metadata object** that is independent of
the UA string. flutter_inappwebview does not expose this metadata
object; an earlier attempt to override the headers via
`URLRequest.headers` (Android `loadUrl(url, additionalHttpHeaders)`) was
empirically confirmed to be discarded by Chromium's network stack —
even on the main document, the headers reach the server as `?1` /
`"Android"` / `"Android WebView"` regardless of the UA string we set.

A site that gates its layout strictly on `Sec-CH-UA-Mobile` rather than
on `navigator.userAgentData` or the UA string will continue to receive
the mobile layout even with a desktop UA. **DuckDuckGo (`duckduckgo.com`)
is a confirmed example**: it reads the header and serves mobile no matter
what UA / shim we present from Dart. WhatsApp Web, Bluesky, and X read
`navigator.userAgentData` and the UA string, so the shim + UA together
fix them.

The only fix from the app side is exposing
`WebSettingsCompat.setUserAgentMetadata()` (Android 13.3+, androidx.webkit
1.5.0+; analogous WKWebView API on iOS) through a
flutter_inappwebview plugin patch. That requires either a fork or an
upstream PR — based on the issue history (`#1458`, `#1713`, `#682`,
`#2132`, `#2528`, all closed without maintainer reply) the upstream
path is dead. Not currently implemented.

---

## Files

| File | Role |
|------|------|
| `lib/services/user_agent_classifier.dart` | `isDesktopUserAgent`, `inferDesktopUaPlatform`, `navigatorPlatformFor`, canonical Firefox desktop UA constants |
| `lib/services/desktop_mode_shim.dart` | `buildDesktopModeShim(userAgent)` — JS source for AT_DOCUMENT_START injection |
| `lib/services/webview.dart` | `createWebView`: injects shim and sets `preferredContentMode` based on `isDesktopUserAgent(config.userAgent)` |
| `lib/web_view_model.dart` | `_migrateUserAgent`: reads legacy `desktopMode` field on import and populates `userAgent` |
| `test/user_agent_classifier_test.dart` | Coverage for the inference helpers |
| `test/desktop_mode_shim_test.dart` | Coverage for the JS shim source generation |
| `test/desktop_mode_migration_test.dart` | Coverage for legacy backup migration |
