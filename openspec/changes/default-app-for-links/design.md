## Context

WebSpace currently treats a site's `initUrl` as its single identity: its name, its cookie-isolation key (via `getBaseDomain(initUrl)`), and the domain it's "allowed" to navigate within (via `getNormalizedDomain(initUrl)`). There is no way for external apps to route a URL into WebSpace; users must copy-paste into the URL bar. The installed-apps list already includes browsers that register https intent-filters; joining them is mechanical on Android but requires care on iOS/macOS.

Key constraints from the existing codebase:
- `flutter_inappwebview` has a **singleton** `CookieManager`. Full per-site cookie jars are impossible without forking the plugin. Isolation is emulated via capture-on-unload / restore-on-load, gated by a mutual-exclusion invariant on base domain.
- State lives in `setState` + SharedPreferences; there is no reactive store. UI must `setState` after external URL arrivals.
- Platform abstraction lives in `platform_support/` (per the existing spec) — we extend it rather than shelling out to `Platform.isAndroid` in `main.dart`.
- FVM-managed Flutter; `@fission-ai/openspec` validator runs in CI.
- Android flavors (`fdroid`, `fmain`, `fdebug`) share `AndroidManifest.xml` in `android/app/src/main/` plus flavor-specific overrides.

Stakeholders: end users (primary friction: copy-paste), F-Droid distribution (must stay unsigned & permission-clean), Play Store review (Android 13+ package-visibility rules).

## Goals / Non-Goals

**Goals:**
- One-tap routing of incoming https URLs to the right existing site, across Android `ACTION_VIEW`/`ACTION_SEND`, iOS Share Extension, macOS Share Extension.
- Per-site multi-domain and wildcard-subdomain claims so a single site can meaningfully represent Google (`google.com`, `*.google.com`, `gmail.com`), a Mastodon instance (`mastodon.social`, `*.mastodon.social`), a GitLab instance, etc.
- Deterministic conflict resolution when claims overlap (most-specific wins; picker on true ties).
- Preserve existing cookie-isolation guarantees in the default "All" webspace while broadening the conflict-detection key from "base domain of `initUrl`" to "any base domain in claim list".
- Tests at the pure-Dart layer for the resolver and conflict validator.

**Non-Goals:**
- Becoming the system default browser on any platform (no `autoVerify` on Android; no `com.apple.developer.web-browser` entitlement on iOS).
- Per-site isolated cookie *jars* (would require forking `flutter_inappwebview`).
- Free-form user-added domain hosts on Android at runtime (Android manifest is static; curated list only).
- Safari Web Extension — explicitly deferred as a follow-on; not in this change.
- Clipboard monitoring or `webspace://` as a general deep-link scheme (only used internally from the iOS/macOS Share Extension → main app hop).
- Changes to named (user-created) webspaces' cookie behavior.

## Decisions

### D1. Domain claim model
Introduce `DomainClaim` (sealed-ish via `kind` enum) stored per `WebViewModel`:

```dart
enum DomainClaimKind { exactHost, wildcardSubdomain, baseDomain }

class DomainClaim {
  final DomainClaimKind kind;
  final String value; // canonical lowercase, no scheme, no port
}
```

Patterns:
- `exactHost` — matches one host (`twitter.com`, `mastodon.social`). Most specific.
- `wildcardSubdomain` — matches any subdomain under `value` (but not `value` itself unless a separate exactHost claim is present). Format stored as `mastodon.social`, UI renders as `*.mastodon.social`.
- `baseDomain` — matches any host whose second-level domain equals `value` (subsumes wildcard + exact on that second-level). Lowest specificity. This is the default synthesized from legacy `initUrl`.

**Alternative considered**: free-form glob/regex. Rejected — users can't reason about it, and the settings UI would have to become a validator.

### D2. Resolver ranking
For an incoming URL `U`, compute `host(U)` and `base(U) = getBaseDomain(host(U))`. For every `(site, claim)`:

| claim.kind          | match condition                          | score |
|---------------------|------------------------------------------|-------|
| exactHost           | `claim.value == host(U)`                 | 300   |
| wildcardSubdomain   | `host(U).endsWith("." + claim.value)`    | 200   |
| baseDomain          | `getBaseDomain(claim.value) == base(U)`  | 100   |

Rules:
- Pick the single highest-scored match.
- Tie at top score → show disambiguation picker (modal bottom sheet).
- No match → Android: re-emit the intent to the chooser excluding WebSpace (`Intent.createChooser` without our component); iOS: return to source app with `extensionContext.completeRequest(returningItems: nil)`; main-app cold-start no-match → open in a nested `InAppBrowser` with "Open in WebSpace…" prompt.

**Alternative considered**: longest-suffix-match without kind weighting. Rejected — `exactHost("mail.google.com")` should beat `baseDomain("google.com")` regardless of string length.

### D3. Claim conflict validation
When a user saves claims for site S:
- Reject any claim whose *base domain* collides with another site's **init-URL base domain** (prevents stealing a sibling's "home").
- Warn (non-blocking) on overlapping-but-not-identical claims with other sites; the resolver can still pick a winner via specificity.

**Alternative considered**: allow collisions and resolve at route time. Rejected — surprises users during editing and invites silent hijacking.

### D4. Android intent-filter shape
- One `<intent-filter>` on `MainActivity` for `ACTION_SEND` with `mimeType="text/plain"` (extract URL from `Intent.EXTRA_TEXT`, tolerate leading/trailing whitespace).
- One `<intent-filter>` per curated host as an `<activity-alias>` targeting `MainActivity`:
  ```xml
  <activity-alias android:name=".handler.TwitterHandler"
                  android:targetActivity=".MainActivity"
                  android:enabled="false"
                  android:exported="true">
    <intent-filter android:autoVerify="false">
      <action android:name="android.intent.action.VIEW"/>
      <category android:name="android.intent.category.DEFAULT"/>
      <category android:name="android.intent.category.BROWSABLE"/>
      <data android:scheme="https" android:host="twitter.com"/>
    </intent-filter>
  </activity-alias>
  ```
- Runtime toggle via `PackageManager.setComponentEnabledSetting` from the Flutter layer through a platform channel.
- No `autoVerify` anywhere. WebSpace only ever appears in the chooser.

**Curated initial set** (final list settled in tasks): `twitter.com`, `x.com`, `linkedin.com`, `mastodon.social`, `reddit.com`, `news.ycombinator.com`, `github.com`, `gitlab.com`, `youtube.com`, `duckduckgo.com`. F-Droid flavor identical (no flavor-gated diffs for this feature).

**Alternative considered**: catch-all `<data android:scheme="https"/>`. Rejected — makes WebSpace appear in the chooser for every link, which users have explicitly said they don't want.

### D5. Intent data delivery Android → Flutter
A lightweight `MethodChannel("webspace/link_intent")`:
- Cold start: on `MainActivity.onCreate`, capture `getIntent()` data/EXTRA_TEXT, stash it on a private field, and respond to Flutter's `getInitialUrl()` call.
- Warm start: `onNewIntent` → `invokeMethod("onUrlArrived", url)`.
- Flutter side: a `LinkIntentService` exposes a `Stream<Uri>`; `WebSpacePage` subscribes in `initState` and calls the resolver.

**Alternative considered**: `uni_links` plugin. Rejected — project already leans on hand-rolled channels; one more small channel is simpler than a dep that also needs iOS config.

### D6. iOS / macOS Share Extension
- New target `WebSpaceShareExtension` with `NSExtensionActivationSupportsWebURLWithMaxCount = 1`, `NSExtensionActivationSupportsText = 1`.
- App Group `group.com.theoden8.webspace` for URL hand-off (write pending URL to shared `UserDefaults`, key `pending_link`).
- Extension calls `extensionContext.open(URL(string: "webspace://open?url=...")!)` to launch main app, then `completeRequest`.
- Main app registers `webspace` URL scheme; on launch, reads pending URL either from the launch URL or from the App Group (belt-and-suspenders), clears the shared key, hands the `Uri` to the same `LinkIntentService.Stream<Uri>` used on Android.

**Alternative considered**: extension renders webview itself. Rejected — memory/CPU budget for extensions is tiny, cookie isolation is unreachable, and the "← Source App" breadcrumb only appears when we actually launch the main app.

### D7. Back-to-referring-app behavior
- Android: intent-launched activity keeps the default task affinity; **do not** set `FLAG_ACTIVITY_NEW_TASK` on `onNewIntent`. Pressing Back returns to the referrer as Android's default stacking gives us for free.
- iOS/macOS: we use the `extensionContext.open(webspace://…)` → OS inserts its own back breadcrumb. Nothing to implement in-app.
- In both cases, if a routed URL causes an unload/reload cycle (same-base-domain conflict inside "All"), that happens *after* the activity is already on-screen, so the back-stack is unaffected.

### D8. Cookie-isolation scope: default "All" webspace only
`per-site-cookie-isolation` currently keys conflict detection on `getBaseDomain(initUrl)`. We widen that key to `{getBaseDomain(initUrl)} ∪ {baseDomain of every claim}` *only when* the active webspace is `__all_webspace__`. In a named webspace the existing behavior is preserved exactly (same conflict key).

Rationale: link intents typically arrive while the user is either on the home screen or the "All" view. Named webspaces are curated sets where the user has explicitly chosen co-residency; we don't silently change their behavior.

**Alternative considered**: always use the widened key. Rejected by the user.

### D9. Routing-overview UI
A new settings screen under the existing settings entry:
```
Link handling
├─ [master switch] Handle shared links
├─ Android only: per-host toggles (read actual component state)
└─ Routing overview: Domain pattern → Site (with conflict badges)
```
Tapping a row opens the owning site's editor (domain-claim list section).

### D10. Legacy migration
On first deserialization after upgrade, any `WebViewModel` without a `domainClaims` field synthesizes `[DomainClaim(baseDomain, getBaseDomain(initUrl))]`. This preserves current conflict-detection behavior exactly (the existing base-domain key is one of the new claim kinds). Serialization omits `domainClaims` when it equals the synthesized default, keeping on-disk output stable for users who never touch the feature.

## Risks / Trade-offs

- **[Risk] Android package-visibility (Play Store) flags broad intent-filters as suspicious** → Mitigation: curated host list, no catch-all, no `QUERY_ALL_PACKAGES`.
- **[Risk] iOS App Group identifier collision across dev/prod/testflight** → Mitigation: use a single identifier tied to bundle, documented in tasks; exit-early if App Group not entitled.
- **[Risk] Resolver drift between platforms** → Mitigation: resolver lives entirely in pure Dart; platform channel only delivers `Uri`. Single source of truth tested in `test/link_routing_test.dart`.
- **[Risk] User enables host handler, uninstalls the only matching site, then taps a link** → Mitigation: on no-match *and* a component is enabled for the host, show a "create new site?" bottom sheet rather than silently bouncing to chooser.
- **[Risk] Widening conflict key in "All" webspace unloads a site the user didn't expect to lose** → Mitigation: show a one-line snackbar explaining the conflict + undo action; log decision.
- **[Trade-off] Curated host list will go stale.** A follow-on issue (not this change) can pull the list from a bundled JSON so updates ship without code changes.
- **[Trade-off] Share Extension adds app-size overhead** (~200–500 KB per platform target). Acceptable given the UX payoff.

## Migration Plan

1. Ship domain-claim model + migration shim + resolver + conflict validator with `domainClaims` not yet surfaced in UI. Tests land here.
2. Ship Android `ACTION_SEND` + `ACTION_VIEW` alias components (all disabled by default) and the platform channel.
3. Ship iOS Share Extension + macOS Share Extension + `webspace://` handler.
4. Ship "Link handling" settings screen and domain-claim editor in site settings.
5. Ship the "All"-webspace conflict-key widening behind an internal feature flag for one release, then remove the flag.

Rollback: each of the 5 steps is independent. If a regression appears post-release, disable the master "Handle shared links" switch (Android additionally disables all components). The resolver and model changes are backward-compatible because the migration shim synthesizes the legacy claim.

## Open Questions

1. Should the curated Android host list be platform-default **on** or **off**? Proposal: default off; user opts in from the new settings screen. Confirms the non-surprising-chooser principle.
2. Do we want `DomainClaim.baseDomain` at all, or is `exactHost + wildcardSubdomain` enough? Proposal: keep it for the legacy-migration case only; UI doesn't expose it as a creation option (only `exact` and `*.wildcard`).
3. Treatment of `http://` (non-TLS) URLs arriving via intent: ignore silently, or route the same as https? Proposal: route identically; users have opted in to our handling.
4. Do we need a "home" claim concept (the one claim whose base domain protects against collisions), or is the site's `initUrl` base domain sufficient? Proposal: stick with `initUrl` base domain — one less concept.
