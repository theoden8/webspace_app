## Why

The Home Shortcut feature (HS-001..HS-005) is currently Android-only — HS-004 hides the menu item on iOS because iOS has no public API equivalent to `ShortcutManager.requestPinShortcut()`. Users have asked for a comparable iOS path. Apple's answer for "discoverable app-defined actions a user can drop on the home screen" is **App Intents** (iOS 16+): we expose `OpenSiteIntent` with a `SiteEntity` parameter; iOS surfaces it in Shortcuts.app, Spotlight, and Siri; the user creates a Shortcut for the desired site and taps "Add to Home Screen" from the Shortcuts.app share sheet.

Safari's "Add to Home Screen" is not viable here — the resulting icon opens the URL in Safari, bypassing per-site cookie isolation, proxy, language, geo, tracking-protection shim. Defeating the entire app.

## What Changes

- **`OpenSiteIntent` App Intent (iOS 16+)**: Swift `AppIntent` conforming to `OpenIntent`, parameterized on a `SiteEntity`. When run, writes the target `siteId` to App Group `UserDefaults` and brings WebSpace to the foreground. The existing `_handleShortcutIntent` flow (which already polls `ShortcutService.getLaunchSiteId()` on resume / cold launch) picks it up.
- **`SiteEntity` + `SiteEntityQuery`**: Dynamic entity backed by the user's actual site list, read from App Group `UserDefaults`. Lets the Shortcuts.app parameter picker show real WebSpace sites by name (and favicon when available) rather than asking the user to type a URL.
- **`WebSpaceShortcuts` provider**: `AppShortcutsProvider` declares "Open Site" as the discoverable App Shortcut. Re-resolved when sites change via `updateAppShortcutParameters()`.
- **Dart `ShortcutService` extension**: `syncSites(...)` writes the site list to App Group `UserDefaults` so `SiteEntityQuery` can read it. Called from `_saveWebViewModels` on iOS. `isAppIntentsSupported()` returns true on iOS 16+ (Swift `if #available`). `getLaunchSiteId()` drains the pending key on iOS, same shape as Android.
- **Menu item on iOS 16+**: Reuses the existing "Home Shortcut" entry. On iOS the label reads "Add to Home Screen" and tapping it opens an instructional dialog with an "Open Shortcuts App" button (deep-linked via `shortcuts://`). HS-005 (hide when pinned) only applies to Android — iOS has no public API to detect home-screen pinning.

## Scope

- **iOS 16+**: full App Intents path.
- **iOS 13/14/15**: feature unavailable, menu item hidden. No fallback URL-scheme onboarding — adds complexity, low value.
- **macOS / Linux / Web**: unchanged (not supported).
- **Android**: unchanged (existing `requestPinShortcut` path).

## Non-Goals

- No App Group favicon sync for v1. `SiteEntity.displayRepresentation` ships site name only; the icon shown in Shortcuts.app is the app icon. Caching favicons to the App Group container so the entity picker shows per-site icons is a future iteration — adds significant download/lifecycle code for marginal UX gain.
- No URL-scheme fallback (`webspace://site?id=...`) for iOS <16. iOS 16 is four years old by 2026; gating cleanly avoids a second code path nobody will read.
- No `OpenAppIntent` for site creation, search, or "open URL". Out of scope — this change is "the iOS equivalent of HS-001..HS-005".
- No deployment-target bump. Existing target stays at 14.0; App Intents code is `@available(iOS 16, *)` gated.
