## Context

WebSpace currently treats a site's `initUrl` as its single identity for navigation: the domain it's "allowed" to navigate within (via `getNormalizedDomain(initUrl)`). There is no way for external apps to route a URL into WebSpace; users must copy-paste into the URL bar.

Cookie/storage isolation is **already handled** elsewhere on master:

- `per-site-containers` (native, default on Android SysWebView 110+ / iOS 17+ / macOS 14+ / Linux WPE 2.40+) — engine-level partitioning. Same-base-domain sites coexist in every webspace. This is the dominant population.
- `per-site-cookie-isolation` (legacy fallback, ISO-001 mutex) — capture-nuke-restore on the singleton `CookieManager`, used on Android <SysWebView 110, iOS <17, macOS <14, Windows, web. Shrinking population.

This change does **not** touch either of those engines. It only adds the link-intent surface (resolver, share intents, `webspace://` scheme).

Stakeholders: end users (primary friction: copy-paste), F-Droid distribution (no GMS, no broad permissions), Play Store review (Android 13+ package-visibility rules).

Constraints from the existing codebase:
- State lives in `setState` + `SharedPreferences`; no reactive store. UI must `setState` after external URL arrivals.
- Platform abstraction lives in `platform_support/`; we extend it rather than shelling out to `Platform.isAndroid` in `main.dart`.
- Logic engines are pure-Dart under `lib/services/*_engine.dart` with mock-friendly interfaces; the resolver follows that pattern.
- FVM-managed Flutter; `@fission-ai/openspec` validator runs in CI.
- Android flavors `fdroid`, `fmain`, `fdebug` share `AndroidManifest.xml`.

## Goals / Non-Goals

**Goals:**
- One-tap routing of incoming URLs to the right existing site, across Android share-sheet (`ACTION_SEND`), iOS Share Extension, macOS Share Extension, and the cross-platform `webspace://` scheme.
- Per-site multi-domain and wildcard-subdomain claims so a single site can meaningfully represent Google (`google.com`, `*.google.com`, `gmail.com`), a Mastodon instance, a GitLab instance, etc.
- Deterministic conflict resolution when claims overlap (most-specific wins; picker on true ties).
- `webspace://open?url=<encoded>` works as a first-class scheme on every supported platform — auto-default with no chooser fight (no other app competes for `webspace://`).
- Pure-Dart resolver with full unit-test coverage; widget tests for the routing dispatch path.

**Non-Goals:**
- Any modification to `per-site-cookie-isolation` (legacy mutex) or `per-site-containers`. The user-stated "always isolate sites" goal is already delivered by container mode; this change does not retro-fit the legacy mutex.
- Becoming the system default browser on any platform (no `autoVerify` on Android; no `com.apple.developer.web-browser` entitlement on iOS).
- Any Android https `ACTION_VIEW` / `BROWSABLE` filter — neither catch-all nor curated per-host aliases. Both are deferred to the libre-mirrors follow-on change.
- iOS Safari Web Extension.
- Free-form user-added Android host handlers.
- Clipboard monitoring.

## Decisions

### D1. Domain claim model

Add `DomainClaim` and `DomainClaimKind` to `lib/web_view_model.dart`:

```dart
enum DomainClaimKind { exactHost, wildcardSubdomain, baseDomain }

class DomainClaim {
  final DomainClaimKind kind;
  final String value; // canonical lowercase, no scheme, no port
}
```

Patterns:
- `exactHost` — matches one host (`twitter.com`, `mastodon.social`). Most specific.
- `wildcardSubdomain` — matches any subdomain under `value` (but not `value` itself unless a separate `exactHost` claim is present). Stored as `mastodon.social`, UI renders as `*.mastodon.social`.
- `baseDomain` — matches any host whose second-level domain equals `value`. Lowest specificity. The default synthesized from legacy `initUrl`.

**Alternative considered**: free-form glob/regex. Rejected — users can't reason about it, and the validator would have to grow.

### D2. Resolver ranking

For an incoming URL `U`, compute `host(U)` and `base(U) = getBaseDomain(host(U))`. For every `(site, claim)`:

| claim.kind         | match condition                          | score |
|--------------------|------------------------------------------|-------|
| exactHost          | `claim.value == host(U)`                 | 300   |
| wildcardSubdomain  | `host(U).endsWith("." + claim.value)`    | 200   |
| baseDomain         | `getBaseDomain(claim.value) == base(U)`  | 100   |

Rules:
- Pick the single highest-scored match.
- Tie at top score → disambiguation picker (modal bottom sheet).
- No match → "Create site for <host>?" bottom sheet.

The resolver is a pure function in `lib/services/link_routing_service.dart`, returning `RoutingMatch.single(WebViewModel)`, `RoutingMatch.ambiguous(List<WebViewModel>)`, or `RoutingMatch.none()`. No platform side-effects.

**Alternative considered**: longest-suffix-match without kind weighting. Rejected — `exactHost("mail.google.com")` should beat `baseDomain("google.com")` regardless of string length.

### D3. Claim conflict validation

When a user saves claims for site S:
- **Reject** any claim whose base domain collides with another site's `initUrl` base domain (prevents stealing a sibling's "home").
- **Warn** (non-blocking) on overlapping-but-not-identical claims with other sites; the resolver still resolves via specificity.

**Alternative considered**: allow collisions and resolve at route time. Rejected — surprises users during editing and invites silent hijacking.

### D4. `webspace://` URL scheme as first-class entry point

Format: `webspace://open?url=<percent-encoded-target-url>`. Target URL must be `http` or `https`; other schemes are dropped at parse time with a snackbar.

Per-platform registration:

| Platform | Registration | Notes |
|----------|--------------|-------|
| Android  | `<intent-filter>` on `MainActivity` with `<action android:name="android.intent.action.VIEW"/>`, `BROWSABLE`, `<data android:scheme="webspace"/>` | No `autoVerify`. Default by virtue of being the only app registered. |
| iOS      | `CFBundleURLTypes` entry in `Info.plist` with `CFBundleURLSchemes = ["webspace"]` | Handled in `application:openURL:options:` / `SceneDelegate` |
| macOS    | Same as iOS in `macos/Runner/Info.plist`. | |
| Linux    | `.desktop` file with `MimeType=x-scheme-handler/webspace;` installed via the linux runner's CMake | xdg-open / GTK URI handlers route `webspace://` to WebSpace. |

The scheme is the **single** entry point that all other launch paths reduce to. Specifically:
- iOS/macOS Share Extension constructs `webspace://open?url=...` and calls `extensionContext.open(...)`.
- Android `ACTION_SEND` Kotlin handler builds a `Uri` and forwards via the channel as `webspace://open?url=...`-shaped data (in-memory only; never round-tripped through the OS).
- External apps' "Open in WebSpace" buttons call `Intent.ACTION_VIEW` on `webspace://open?url=...`.

This collapses all entry-point parsing to a single Dart function (`LinkIntentService.parseWebspaceUri(Uri)`), simplifying tests.

**Alternative considered**: `webspace://<host>/<path>` (drop `https://`). Rejected — collides with relative-path semantics in some URI parsers and can't carry the `https` vs `http` distinction unambiguously.

### D5. Intent data delivery: platform → Flutter

A single `MethodChannel("webspace/link_intent")` with:
- `Future<String?> getInitialUrl()` — main app's first call after `runApp()`; returns the cold-start URL (whether from `webspace://`, `ACTION_SEND`, or iOS/macOS launch URL). Cleared after first read.
- Event `onUrlArrived(String url)` — warm-start delivery from `onNewIntent` (Android), `application:openURL:options:` / `SceneDelegate` (iOS), `application:openURL:` (macOS), `signal::open` (Linux GApplication).

Flutter side: `LinkIntentService` exposes `Stream<Uri>`. `WebSpacePage` subscribes in `initState`, runs each URL through `parseWebspaceUri` (which strips the `webspace://open?url=` wrapper if present and validates the target) before passing it to the resolver.

### D6. iOS / macOS Share Extension

- New target `WebSpaceShareExtension` with `NSExtensionActivationSupportsWebURLWithMaxCount = 1`, `NSExtensionActivationSupportsText = 1`.
- App Group `group.com.theoden8.webspace` for belt-and-suspenders URL hand-off (write `pending_link` to shared `UserDefaults` in case the `extensionContext.open` route races a backgrounded main app).
- Extension calls `extensionContext.open(URL(string: "webspace://open?url=<encoded>")!)` then `completeRequest(returningItems: nil)`.
- Main app reads URL from launch URL or App Group; clears the App Group key after consume.

### D7. Back-to-referring-app behavior

- **Android**: do not set `FLAG_ACTIVITY_NEW_TASK` on `onNewIntent` handling. The intent-launched activity inherits the referrer's task; system Back returns to it.
- **iOS / macOS**: `extensionContext.open(webspace://...)` triggers the OS's "← Source App" status-bar breadcrumb. Nothing to implement in-app.
- **Linux**: `webspace://` URLs typically come from `xdg-open` invocations launched from a terminal or another app; the spawned WebSpace process is detached, so there's no back-stack relationship. Acceptable for now.

### D8. Routing-overview UI

A new "Link handling" screen under settings:
```
Link handling
├─ [master switch] Handle shared links
└─ Routing overview: Domain pattern → Site (with conflict badges)
```
Tapping a row opens the owning site's editor, scrolled to the domain-claim section.

The master switch persists via `SharedPreferences` key `link_handling_enabled`. When off:
- `LinkIntentService` ignores incoming URLs (logs and drops).
- iOS/macOS Share Extension reads the flag from the App Group on activation; if off, presents a "WebSpace link handling is disabled" toast and dismisses.

No per-host toggles. (Curated host activity-aliases are deferred to libre-mirrors.)

### D9. Legacy migration

On first deserialization after upgrade, any `WebViewModel` without a `domainClaims` field synthesizes `[DomainClaim(baseDomain, getBaseDomain(initUrl))]`. Serialization omits `domainClaims` when it equals the synthesized default, keeping on-disk output stable for users who never touch the feature.

### D10. Scoping versus current cookie-isolation engines

- **Container mode** (`_useContainers == true`, dominant): the resolver activates the matched site; engine-level isolation handles state. No conflict-finding, no unload, no capture-nuke-restore. The intent-routed activation goes through the standard `_setCurrentIndex` path.
- **Legacy mode** (`_useContainers == false`): the resolver activates the matched site, `_setCurrentIndex` calls `SiteActivationEngine.findDomainConflict`, and any same-base-domain conflict triggers the existing capture-nuke-restore cycle. This is byte-identical to today's behavior; the only new input is "the user's selected site came from an intent" rather than "the user's selected site came from a tap in the drawer."

No change to `per-site-cookie-isolation` or `per-site-containers` specs.

## Risks / Trade-offs

- **[Risk] iOS App Group identifier collision across dev/prod/testflight** → Mitigation: single identifier tied to bundle, documented in tasks; exit-early if App Group not entitled.
- **[Risk] Resolver drift between platforms** → Mitigation: resolver lives entirely in pure Dart; platform channel only delivers a `Uri` (or `String`). Single source of truth tested in `test/link_routing_test.dart`.
- **[Risk] User enables `webspace://` opener, taps a malformed URL, app crashes** → Mitigation: `parseWebspaceUri` returns `null` for any invalid input and surfaces a snackbar; never throws.
- **[Risk] Linux `.desktop` registration fragmenting across distros** → Mitigation: install at `~/.local/share/applications/webspace.desktop` via the runner's installer; document `update-desktop-database` invocation in build script.
- **[Risk] Routing into a site that's outside the current named webspace surprises the user** → Mitigation: WEBSPACE-011 forces a switch to "All" with a snackbar ("Switched to All to open <url> in <site>"), preserving discoverability.
- **[Trade-off] Without https `ACTION_VIEW` (deferred), users tapping a plain twitter.com link in another app still need to use Share → WebSpace.** Acceptable; the libre-mirrors change will close the gap.
- **[Trade-off] `webspace://` is novel; users won't intuit it.** Surfaced via in-app help text and the routing-overview footer ("Authoring a link to open in WebSpace? Use `webspace://open?url=<your-link>`").

## Migration Plan

1. Domain-claim model + migration shim + resolver + claim validator (no UI surfaced). Tests land here.
2. `webspace://` scheme registration on all four platforms + platform channel + cold/warm-start handling.
3. Android `ACTION_SEND` handler.
4. iOS/macOS Share Extensions.
5. "Link handling" settings screen, domain-claim editor, picker, no-match bottom sheet.
6. WEBSPACE-011 (auto-switch to "All" when matched site isn't in current webspace).

Each step is independent. Rollback: disable the master "Handle shared links" switch; the resolver and model changes are backward-compatible because the migration shim synthesizes the legacy claim.

## Open Questions

1. Should `webspace://open?url=...` accept additional query parameters in the future (e.g., `&siteHint=<siteId>` to suggest which site)? Proposal: define the minimum (`url=`) now; reserve other parameter names by ignoring them gracefully.
2. Treatment of `http://` (non-TLS) target URLs arriving via `webspace://open?url=...` or share intent: ignore silently, or route the same as https? Proposal: route identically — users have explicitly opted in by sharing.
3. Linux back-to-referrer: leave as a known gap for now, or attempt parent-PID heuristics? Proposal: known gap.
