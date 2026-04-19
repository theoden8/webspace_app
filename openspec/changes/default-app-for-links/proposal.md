## Why

Users who frequent Twitter/X, LinkedIn, Mastodon instances, GitLab instances, etc. currently have to copy-paste URLs from other apps into WebSpace's URL bar to open them in the right site with its isolated cookies. The OS-level "Open with" chooser (Android) and share sheet (iOS/macOS) already solve this for native apps — WebSpace should participate. In addition, a site today is tied to a single initial URL for navigation/cookie purposes, which doesn't match reality (Google services span several domains; Mastodon/GitLab instances span subdomains; a user may want one "Google" site to handle `mail.google.com`, `drive.google.com`, and `gmail.com`).

## What Changes

- Android `ACTION_SEND` handler: any app can share a URL to WebSpace; it routes the URL into the matching site's webview.
- Android `ACTION_VIEW` / `BROWSABLE` intent-filters for a curated set of https hosts, with per-host user toggles implemented via `<activity-alias>` + `PackageManager.setComponentEnabledSetting`. WebSpace appears in the "Open with" chooser but does **not** request `autoVerify` — the user always picks.
- iOS Share Extension (`NSExtensionActivationSupportsWebURLWithMaxCount`): opens shared URLs in the main app via `webspace://open?url=...`.
- iOS Safari Web Extension (optional follow-on): redirect link taps in Safari to WebSpace.
- macOS Share Extension: equivalent of iOS.
- Per-site **domain claim list**: each site stores a list of domain patterns it handles. Pattern shapes:
  - exact host (`twitter.com`)
  - wildcard subdomain (`*.mastodon.social`)
  - multiple patterns per site (e.g., one "Google" site handling `google.com`, `*.google.com`, `gmail.com`)
- **URL routing resolver**: given an incoming URL, find the site whose claim list matches most specifically (exact host > wildcard subdomain > base-domain fallback). On true ties, surface a picker. On no match, fall back to the OS chooser (Android) / pass the URL back to the source / open in a nested webview (iOS).
- **Global routing overview UI**: a settings screen listing every claimed domain pattern → site, conflict warnings, and a master "Handle shared links" switch. Shows which `<activity-alias>` components are enabled on Android.
- **Domain-claim conflict prevention**: a site cannot claim a domain pattern whose base domain is the *home* (init URL) base domain of another site; attempting to do so surfaces a validation error in site editing.
- **Back-to-referring-app behavior**: when launched via intent (Android) or via Share Extension → main app (iOS/macOS), the system's own return affordance is used — on Android by avoiding `FLAG_ACTIVITY_NEW_TASK` for intent-launched activities, on iOS/macOS via the OS-provided status-bar back breadcrumb.
- **Always-on cookie isolation in the default "All" webspace**: within `__all_webspace__`, each site is treated as its own cookie-isolated container and mutual-exclusion rules apply based on the site's full domain-claim list (not just its init-URL base domain). Named user-created webspaces retain their current behavior. This guarantees that link-intent-routed URLs arriving while the user is browsing "All" always land in an isolated per-site context.
- Unit tests for the routing resolver (ranking, ties, no-match, wildcard semantics), manifest-component toggling, and domain-claim conflict validation. Manual test matrix documented per platform.

## Capabilities

### New Capabilities
- `link-intent-routing`: share/open-intent entry points (Android `ACTION_SEND` + `ACTION_VIEW`, iOS/macOS Share Extension, iOS Safari Web Extension), per-site domain-claim list with exact/wildcard/multi-domain patterns, URL-to-site resolver with most-specific-match ranking and chooser fallback, global routing overview settings screen, per-host `<activity-alias>` toggles, back-to-referring-app behavior.

### Modified Capabilities
- `per-site-cookie-isolation`: domain conflict detection uses the site's full domain-claim list (not just its init-URL base domain) when the active webspace is the default "All" webspace; add validation preventing one site from claiming another site's home base domain.
- `webspaces`: document that the default "All" webspace enforces per-site cookie isolation; named webspaces unchanged.

## Impact

- **Android manifest**: new `<intent-filter>`s on `MainActivity` (or a dedicated `IntentRouterActivity`); new `<activity-alias>` entries per curated domain; new `ACTION_SEND` filter.
- **iOS project**: new Share Extension target with App Group for URL hand-off, `webspace://` URL scheme, optional Safari Web Extension target.
- **macOS project**: new Share Extension target.
- **Flutter code**:
  - `WebViewModel`: new `domainClaims: List<DomainClaim>` field; JSON migration so legacy sites synthesize `[DomainClaim.exact(baseDomain(initUrl))]`.
  - `lib/main.dart`: cold-start/warm-start URL handling from platform channel, routing resolver, conflict-resolution picker.
  - `lib/services/`: new `link_routing_service.dart` (resolver + conflict validation); platform channel wrapper for intent data.
  - Site editor UI: domain-claim list editor, validation errors.
  - Settings: new "Link handling" screen (global toggle, per-domain toggles, routing overview).
- **Specs touched**: `per-site-cookie-isolation/spec.md` (delta), `navigation/spec.md` (incoming-URL flow touches this surface).
- **Dependencies**: none new expected; `flutter_inappwebview` already covers rendering. Platform channels via existing plumbing.
- **Migration**: existing `WebViewModel`s auto-synthesize a single exact-host claim on first load; no user action required.
- **Security**: manifest-declared hosts are visible to all apps (package visibility); no user data is exposed by activity-alias state. Share Extension App Group keys are WebSpace-scoped.
