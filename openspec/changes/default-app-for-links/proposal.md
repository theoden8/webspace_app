## Why

Users who frequent Twitter/X, LinkedIn, Mastodon instances, GitLab instances, etc. currently have to copy-paste URLs from other apps into WebSpace's URL bar to open them in the right site with its isolated cookies. Android's share sheet and iOS/macOS Share Extensions already solve this for native apps — WebSpace should participate. In addition, a site today is tied to a single initial URL for navigation/cookie purposes, which doesn't match reality (Google services span several domains; Mastodon/GitLab instances span subdomains; a user may want one "Google" site to handle `mail.google.com`, `drive.google.com`, and `gmail.com`).

## What Changes

- Android `ACTION_SEND` handler: any app can share a URL (as `text/plain`) to WebSpace; it routes the URL into the matching site's webview.
- iOS Share Extension (`NSExtensionActivationSupportsWebURLWithMaxCount`): opens shared URLs in the main app via `webspace://open?url=...`.
- macOS Share Extension: equivalent of iOS.
- Per-site **domain claim list**: each site stores a list of domain patterns it handles. Pattern shapes:
  - exact host (`twitter.com`)
  - wildcard subdomain (`*.mastodon.social`)
  - multiple patterns per site (e.g., one "Google" site handling `google.com`, `*.google.com`, `gmail.com`)
- **URL routing resolver**: given an incoming URL, find the site whose claim list matches most specifically (exact host > wildcard subdomain > base-domain fallback). On true ties, surface a picker. On no match, offer "create new site for <host>?".
- **Global routing overview UI**: a settings screen listing every claimed domain pattern → site, conflict warnings, and a master "Handle shared links" switch.
- **Domain-claim conflict prevention**: a site cannot claim a domain pattern whose base domain is the *home* (init URL) base domain of another site; attempting to do so surfaces a validation error in site editing.
- **Back-to-referring-app behavior**: when launched via `ACTION_SEND` (Android) or via Share Extension → main app (iOS/macOS), the system's own return affordance is used — on Android by avoiding `FLAG_ACTIVITY_NEW_TASK` on intent handling, on iOS/macOS via the OS-provided status-bar back breadcrumb.
- **Always-on cookie isolation in the default "All" webspace**: within `__all_webspace__`, each site is treated as its own cookie-isolated container and mutual-exclusion rules apply based on the site's full domain-claim list (not just its init-URL base domain). Named user-created webspaces retain their current behavior. This guarantees that link-intent-routed URLs arriving while the user is browsing "All" always land in an isolated per-site context.
- Unit tests for the routing resolver (ranking, ties, no-match, wildcard semantics) and domain-claim conflict validation. Manual test matrix documented per platform.

### Explicitly out of scope (deferred to a future change)

- **Android `ACTION_VIEW` / `BROWSABLE` intent-filters** for curated hosts (appearing in the "Open with" chooser for specific https hosts like twitter.com). Planned as the entry point for a follow-on change that also ships **libre-mirror presets** — e.g., routing `reddit.com` / `twitter.com` / `youtube.com` taps into WebSpace sites configured against alternative frontends (redlib, nitter, invidious/piped). The domain-claim model landing here is forward-compatible: a future site for redlib can claim `exactHost:reddit.com` with no further schema changes.
- iOS Safari Web Extension.
- Free-form user-added Android host handlers (Android manifest is static; out of scope indefinitely).

## Capabilities

### New Capabilities
- `link-intent-routing`: share-intent entry points (Android `ACTION_SEND`, iOS/macOS Share Extension), per-site domain-claim list with exact/wildcard/multi-domain patterns, URL-to-site resolver with most-specific-match ranking and picker/no-match fallback, global routing overview settings screen, back-to-referring-app behavior.

### Modified Capabilities
- `per-site-cookie-isolation`: domain conflict detection uses the site's full domain-claim list (not just its init-URL base domain) when the active webspace is the default "All" webspace; add validation preventing one site from claiming another site's home base domain.
- `webspaces`: document that the default "All" webspace enforces claim-aware cookie isolation; named webspaces unchanged.

## Impact

- **Android manifest**: new `ACTION_SEND` `<intent-filter>` with `mimeType="text/plain"` on `MainActivity`. No `ACTION_VIEW` hosts in this change.
- **iOS project**: new Share Extension target with App Group for URL hand-off, `webspace://` URL scheme.
- **macOS project**: new Share Extension target.
- **Flutter code**:
  - `WebViewModel`: new `domainClaims: List<DomainClaim>` field; JSON migration so legacy sites synthesize `[DomainClaim.baseDomain(getBaseDomain(initUrl))]`.
  - `lib/main.dart`: cold-start/warm-start URL handling from platform channel, routing resolver, conflict-resolution picker.
  - `lib/services/`: new `link_routing_service.dart` (resolver + conflict validation) and `link_intent_service.dart` (platform channel wrapper).
  - Site editor UI: domain-claim list editor, validation errors.
  - Settings: new "Link handling" screen (global toggle + routing overview).
- **Specs touched**: `per-site-cookie-isolation/spec.md` (delta), `webspaces/spec.md` (delta).
- **Dependencies**: none new expected; `flutter_inappwebview` already covers rendering. Platform channels via existing plumbing.
- **Migration**: existing `WebViewModel`s auto-synthesize a single `baseDomain` claim on first load; no user action required.
- **Security**: Share Extension App Group keys are WebSpace-scoped. Share intents carry only user-initiated URLs; no broad package-visibility declarations added.
