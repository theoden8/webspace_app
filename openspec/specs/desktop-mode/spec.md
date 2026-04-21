# Desktop Mode Specification

## Purpose

Allow users to request the desktop version of sites on a per-site basis, producing the same effect as Chrome's or Safari's "Request desktop site" menu item.

## Status

- **Date**: 2026-04-21
- **Status**: Implemented

---

## Problem Statement

Some sites (e.g. WhatsApp Web, Bluesky, messaging portals) do not expose their full UI in a mobile webview even when a desktop User-Agent string is set. Those sites also inspect viewport width, touch capability, pointer type, and high-entropy client hints — so swapping only the UA string leaves every other "mobile" signal intact and the site continues to serve its mobile layout.

The webview plugin already exposes a native desktop-mode flag (`InAppWebViewSettings.preferredContentMode`) that the underlying engine handles in a platform-appropriate way. Exposing it as a per-site toggle is a one-setting change that flips all the relevant signals together, rather than hand-rolling a JS shim over `navigator.userAgent`, `navigator.maxTouchPoints`, `window.innerWidth`, and the viewport meta tag.

---

## Requirements

### Requirement: DM-001 - Per-Site Desktop Toggle

The system SHALL expose a per-site "Desktop mode" switch in the site settings screen that requests the desktop version of the site.

#### Scenario: Enable desktop mode from settings

**Given** the user is on the Settings screen for a site
**When** the user enables the "Desktop mode" toggle and saves
**Then** the `desktopMode` field is persisted on the site
**And** the webview is recreated with `preferredContentMode: DESKTOP`
**And** the site loads its desktop layout

#### Scenario: Disable desktop mode

**Given** a site has `desktopMode = true`
**When** the user disables the toggle and saves
**Then** the webview is recreated with `preferredContentMode: RECOMMENDED`
**And** the site loads its mobile layout

---

### Requirement: DM-002 - Default Off

The system SHALL default `desktopMode` to `false` for all sites, including legacy sites restored from backups that predate this feature.

#### Scenario: Existing site without the field

**Given** a site JSON missing the `desktopMode` key (e.g. restored from an older backup)
**When** the site is deserialized
**Then** `desktopMode` is `false`

#### Scenario: Newly created site

**Given** the user adds a new site
**Then** `desktopMode` is `false` by default

---

### Requirement: DM-003 - Backup Round-Trip

The system SHALL persist `desktopMode` as part of the site's JSON so it round-trips through settings backup and restore.

#### Scenario: Export and re-import

**Given** site "WhatsApp" has `desktopMode = true`
**When** the user exports settings and re-imports the file into a fresh install
**Then** "WhatsApp" is restored with `desktopMode = true`

---

### Requirement: DM-004 - Cookie Isolation Unaffected

Desktop mode SHALL NOT change per-site cookie isolation semantics. A site's `siteId` and domain-conflict rules are independent of its content mode.

#### Scenario: Toggling desktop mode preserves siteId

**Given** site "X" has `desktopMode = false` and a stable `siteId`
**When** the user enables "Desktop mode" and saves
**Then** the site's `siteId` is unchanged
**And** cookies previously stored under that `siteId` continue to load for the site

#### Scenario: Domain conflict detection ignores desktopMode

**Given** two sites share a base domain and must not be loaded simultaneously
**When** one of them has `desktopMode = true` and the other has `desktopMode = false`
**Then** the cookie isolation engine still treats them as conflicting
**And** switching between them triggers the standard unload/cookie-save/restore path

---

## Implementation Details

### Data Model

**WebViewModel** (`lib/web_view_model.dart`):
- `bool desktopMode = false` — per-site flag
- Serialized in `toJson()` / `fromJson()` with default `false`
- Passed into `WebViewConfig` at the `getWebView` call site

### Webview Configuration

**WebViewConfig** (`lib/services/webview.dart`):
- `final bool desktopMode` — propagated to the `InAppWebViewSettings` at webview creation

**InAppWebViewSettings** (`lib/services/webview.dart`, `createWebView`):
- `preferredContentMode: config.desktopMode ? UserPreferredContentMode.DESKTOP : UserPreferredContentMode.RECOMMENDED`

The `preferredContentMode` setting is supported on Android, iOS 13+, and macOS 10.15+ by flutter_inappwebview. Internally:
- **iOS / macOS**: maps to `WKWebpagePreferences.preferredContentMode`, which controls UA, viewport, and touch semantics at the WebKit level.
- **Android**: maps to `useWideViewPort`/`loadWithOverviewMode` plus a desktop UA override, producing the same end-user effect.

### UI

**SettingsScreen** (`lib/screens/settings.dart`):
- `SwitchListTile` placed immediately after the "Full screen mode" toggle, titled "Desktop mode"
- Subtitle: "Request the desktop version of sites"
- Tooltip explains that the toggle overrides any custom User-Agent while active, because `preferredContentMode: DESKTOP` synthesizes its own UA on Android/iOS

### Settings Persistence / Apply

Settings save always disposes the webview (`widget.webViewModel.disposeWebView()`), forcing recreation with the new `preferredContentMode`. No separate reload path is required.

### Cookie Isolation

`desktopMode` is orthogonal to the cookie isolation engine. No changes to `CookieIsolationEngine` or `siteId` generation.

### Settings Backup

`desktopMode` is carried via `WebViewModel.toJson()` / `fromJson()` and ships inside the `sites` array of the backup file. No entry is needed in `kExportedAppPrefs` (that registry is for global prefs, not per-site model fields).

---

## Files Modified

| File | Changes |
|------|---------|
| `lib/web_view_model.dart` | Added `desktopMode` field, constructor param, toJson/fromJson entry; threaded through `WebViewConfig` at `getWebView` call site |
| `lib/services/webview.dart` | Added `desktopMode` to `WebViewConfig`; wired `preferredContentMode` in `createWebView`'s `InAppWebViewSettings` |
| `lib/screens/settings.dart` | Added `_desktopMode` state, initState wiring, save wiring, and a `SwitchListTile` with hint |
| `openspec/specs/desktop-mode/spec.md` | This spec |

---

## Manual Test Procedure

1. Add WhatsApp Web (`https://web.whatsapp.com`) as a site.
2. Observe the mobile "WhatsApp Web only works on desktop" page.
3. Open site Settings, enable "Desktop mode", save.
4. Verify the page reloads and now shows the desktop QR-code login flow.
5. Repeat with `https://bsky.app` — with desktop mode off, the compact mobile layout is rendered; with desktop mode on, the full three-column layout appears.
6. Export settings, wipe app data, re-import. Verify the desktop-mode sites still have the toggle on.
7. Disable desktop mode on a site, save. Verify the webview reloads with the mobile layout restored.
8. Set a custom User-Agent string on a site, then enable desktop mode. Verify the site gets the desktop layout (the platform's synthesized desktop UA takes precedence while the toggle is on — this is documented in the tooltip).

---

## Rationale for Using `preferredContentMode`

The alternative of keeping the existing user-agent-only toggle and layering JavaScript overrides (spoofing `navigator.userAgent`, `navigator.maxTouchPoints`, `window.innerWidth`, the viewport meta tag, and `navigator.userAgentData`) was rejected for three reasons:

1. **Surface area**: every sniffable API would need to be kept in sync with browser evolution.
2. **CSP conflicts**: some sites block inline scripts, preventing early UA/touch overrides from running.
3. **Platform parity**: `preferredContentMode` uses each platform's native code path, so Android, iOS, and macOS all converge on the same behavior with a single setting rather than three bespoke shims.
