## Why

Users who frequent Twitter/X, LinkedIn, Mastodon instances, GitLab instances, etc. currently have to copy-paste URLs from other apps into WebSpace's URL bar to open them in the right site with its isolated state. Android's share sheet and iOS/macOS Share Extensions already solve this for native apps — WebSpace should participate. In addition, a site today is tied to a single initial URL for navigation purposes, which doesn't match reality (Google services span several domains; Mastodon/GitLab instances span subdomains; a user may want one "Google" site to handle `mail.google.com`, `drive.google.com`, and `gmail.com`).

The "always-isolate-each-site" goal that surfaced during scoping is **already satisfied on master** by `per-site-containers`: in container mode (Android SysWebView 110+, iOS 17+, macOS 14+, Linux WPE 2.40+) sites have engine-level partitioning and coexist concurrently in every webspace, including "All". Only the legacy `CookieIsolationEngine` fallback (Android <SysWebView 110, iOS <17, macOS <14, Windows, web) still applies the ISO-001 mutex; this change does not modify that behavior.

## What Changes

- Per-site **domain claim list**: each site stores a list of patterns it handles. Pattern shapes:
  - exact host (`twitter.com`)
  - wildcard subdomain (`*.mastodon.social`)
  - multiple patterns per site (e.g., one "Google" site handling `google.com`, `*.google.com`, `gmail.com`)
- **URL routing resolver**: given an incoming URL, find the site whose claim list matches most specifically (exact host > wildcard subdomain > base-domain fallback). On true ties, surface a picker. On no match, offer "create new site for <host>?".
- **Domain-claim conflict prevention**: a site cannot claim a domain pattern whose base domain equals another site's `initUrl` base domain; the editor surfaces a validation error.
- **`webspace://` URL scheme as a first-class cross-platform entry point**: registered on Android (intent-filter), iOS/macOS (`CFBundleURLTypes`), Linux (`.desktop` file `MimeType=x-scheme-handler/webspace;`). Format: `webspace://open?url=<encoded-target-url>`. Used by:
  - the iOS/macOS Share Extension to hand the URL off from extension process to main app
  - external apps wanting to provide an "Open in WebSpace" button without competing with browsers in the https chooser
  - paste-and-tap from Notes/Messages/etc.
- **Android `ACTION_SEND` (share-intent) handler**: any app can share a URL (as `text/plain`) to WebSpace via the share sheet; it routes through the resolver.
- **iOS Share Extension** (`NSExtensionActivationSupportsWebURLWithMaxCount`): opens shared URLs in the main app via `webspace://open?url=...`.
- **macOS Share Extension**: equivalent of iOS.
- **Global routing overview UI**: a settings screen listing every claimed domain pattern → site, conflict warnings, and a master "Handle shared links" switch.
- **Back-to-referring-app behavior**: on Android, the `ACTION_SEND` activity inherits its task from the referrer (no `FLAG_ACTIVITY_NEW_TASK`); on iOS/macOS the OS-provided status-bar back breadcrumb returns the user to source.
- **WEBSPACE-011 (new requirement)**: when an intent-routed URL targets a site outside the current webspace, the system switches to the default "All" webspace before activating the site.
- Unit tests for the routing resolver (ranking, ties, no-match, wildcard semantics) and domain-claim conflict validation. Manual test matrix per platform.

### Explicitly out of scope (deferred to a future change)

- **Android `ACTION_VIEW` / `BROWSABLE` intent-filters for https** — neither curated per-host aliases nor a catch-all `<data android:scheme="https"/>` opener. Both are planned for a follow-on change that also ships **libre-mirror presets** (e.g., routing `reddit.com` / `twitter.com` / `youtube.com` taps into WebSpace sites configured against alternative frontends — redlib, nitter, invidious/piped). The domain-claim model landing here is forward-compatible.
- iOS Safari Web Extension.
- Free-form user-added Android https host handlers (Android manifest is static; out of scope indefinitely).
- Modifications to `per-site-cookie-isolation` (legacy engine) or `per-site-containers` (native engine) — both already deliver the isolation behavior the user originally asked for in container mode; the legacy mutex is left alone.

## Capabilities

### New Capabilities
- `link-intent-routing`: per-site domain-claim list (exact / wildcard-subdomain / base-domain), URL-to-site resolver with most-specific-match ranking and picker/no-match fallback, share-intent entry points (Android `ACTION_SEND`, iOS/macOS Share Extension), `webspace://open?url=...` cross-platform URL scheme, global routing overview settings screen, back-to-referring-app behavior.

### Modified Capabilities
- `webspaces`: add WEBSPACE-011 — intent-routed URL targeting a site outside the current webspace switches to "All" before activation.

## Impact

- **Android manifest**: new `ACTION_SEND` `<intent-filter>` with `mimeType="text/plain"` on `MainActivity`; new `<intent-filter>` for `<data android:scheme="webspace"/>`. No https `ACTION_VIEW` filters.
- **iOS project**: new Share Extension target with App Group for URL hand-off; `webspace` registered in `CFBundleURLTypes`.
- **macOS project**: new Share Extension target; `webspace` registered in `CFBundleURLTypes`.
- **Linux project**: install a `.desktop` file with `MimeType=x-scheme-handler/webspace;` so xdg-open dispatches `webspace://` URLs to WebSpace.
- **Flutter code**:
  - `WebViewModel`: new `domainClaims: List<DomainClaim>` field; JSON migration so legacy sites synthesize `[DomainClaim.baseDomain(getBaseDomain(initUrl))]`.
  - `lib/main.dart`: cold-start/warm-start URL handling from platform channel, calls into the routing resolver.
  - `lib/services/`: new `link_routing_service.dart` (resolver + claim conflict validation) and `link_intent_service.dart` (platform-channel wrapper, also handles `webspace://open?url=...` parsing).
  - Site editor UI: domain-claim list editor, validation errors.
  - Settings: new "Link handling" screen (master toggle + routing overview).
- **Specs touched**: `webspaces/spec.md` (delta — adds WEBSPACE-011). Neither `per-site-cookie-isolation` nor `per-site-containers` is modified by this change.
- **Dependencies**: none new expected; `flutter_inappwebview` already covers rendering. Platform channels via existing plumbing.
- **Migration**: existing `WebViewModel`s auto-synthesize a single `baseDomain` claim on first load; no user action required. Serialization omits `domainClaims` when it equals the synthesized default to keep on-disk output stable for users who never touch the feature.
- **Security**: Share Extension App Group keys are WebSpace-scoped. `webspace://` URLs only carry user-initiated target URLs and are validated (must parse to a `Uri`, must be `http`/`https`).
