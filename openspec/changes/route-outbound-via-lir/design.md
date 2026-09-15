## Context

LIR currently handles **inbound** URLs (Android `ACTION_SEND`, iOS/macOS Share Extension, `webspace://`) by running them through `LinkRoutingService.resolve` and dispatching via `LinkIntentDispatchEngine`. The cross-domain **outbound** path inside a webview today bypasses LIR entirely:

- `NavigationDecisionEngine.decideShouldOverrideUrlLoading` returns `blockOpenNested` for a gesture-driven cross-domain navigation.
- `WebViewModel`'s callback invokes `launchUrlFunc(url, ...)` with **the source site's** siteId / cookies / container / settings.
- The user lands on the destination domain inside the source's session.

That's good for "open this article in the same private context as the search engine I'm using" but bad for "open this GitHub link in *my GitHub site* where I'm signed in". LIR has the data (per-site `domainClaims`) to make the latter choice; we just don't consult it on the outbound path.

This change adds a second LIR entry point and threads it into the two existing nested-launch call sites in `web_view_model.dart`. The resolver itself does not change; the new logic is one layer above it (`resolveOutbound`) plus a new dispatch entry (`dispatchOutbound`).

Constraints from the existing codebase:

- Per-site settings MUST round-trip to nested webviews (CLAUDE.md). The destination-side `WebViewConfig` carrying destination cookies/container is already what `_executeOpenNested` (LIR-011) produces. Outbound reuses that primitive.
- Logic engines are pure-Dart. The resolution layer goes in `link_routing_service.dart`; the dispatch decision goes in `link_intent_dispatch_engine.dart`; the executor lives in `_WebSpacePageState`.
- The `LinkIntentDispatchEngine` already emits a `DispatchOpenNested` action used by the inbound LIR-011 cross-domain-share path. Outbound reuses that variant with a new `sourceIsParent` flag controlling whether `_maybeSwitchToAllForSite` runs.
- Both legacy and container cookie engines must work. Container mode just opens the nested view with `containerId == destination.siteId`. Legacy mode pushes the nested view; the singleton CookieManager already has the destination's cookies installed via the source-of-truth replay in `WebViewFactory` when the nested view loads. No change to either engine.

## Goals / Non-Goals

**Goals:**
- Click on a GitHub link inside DDG lands in the user's GitHub site (cookies, container, login) when the user has opted DDG into launcher mode.
- Source preference disambiguates multi-candidate cases (work-GitHub vs personal-GitHub) without showing a picker every time.
- Silent fall-through to today's behaviour for: launcher mode off, no destination match, ambiguous without a learned source pref, target resolves to source itself.
- Back-gesture from the hijacked nested view returns the user to the source site, in the same webspace they started in.

**Non-Goals:**
- Modifying `NavigationDecisionEngine` — it still owns "should this be nested at all". This change runs *after* `blockOpenNested` is decided.
- Hijacking `window.open` / `target=_blank` popups (handled in `inappbrowser.dart`'s popup-window path).
- Auto-creating a new site for an unmatched outbound URL.
- Inbound LIR semantics — proposal, picker contents, and webspace-switch behaviour for shared URLs stay exactly as in `default-app-for-links`.

## Decisions

### D1. Outbound preference data shape

Per-site additions to `WebViewModel`:

```dart
class OutboundPreference {
  final DomainClaim claim;        // reused from link-intent-routing
  final String targetSiteId;      // which site to route to
}

class WebViewModel {
  bool routeOutboundLinks;                       // default false
  List<OutboundPreference> outboundPreferences;  // default []
  // ...
}
```

`OutboundPreference` lives in `lib/services/outbound_preference.dart` (separate file to avoid the `web_view_model.dart` import cycle that already led to extracting `DomainClaim` into `lib/services/domain_claim.dart`).

JSON shape on `WebViewModel`:

```json
{
  "routeOutboundLinks": true,
  "outboundPreferences": [
    {"claim": {"kind": "exactHost", "value": "github.com"}, "targetSiteId": "work-github-abc123"},
    {"claim": {"kind": "wildcardSubdomain", "value": "github.com"}, "targetSiteId": "work-github-abc123"}
  ]
}
```

`toJson` omits `routeOutboundLinks` when `false` and `outboundPreferences` when empty, keeping legacy on-disk output unchanged.

**Alternative considered**: a single `Map<String, String>` keyed by destination host or baseDomain. Rejected — the user explicitly chose `DomainClaim` granularity. `wildcardSubdomain(google.com) → google-site` lets one entry cover `gmail.com`, `mail.google.com`, `drive.google.com` the same way LIR-001 claims already do. Reusing `DomainClaim` also means the existing canonicalisation + UI editor primitives carry over.

**Alternative considered**: store outbound prefs as a global registry keyed by `(sourceSiteId, claim)` rather than per-site. Rejected — round-tripping per-site state through `WebViewModel.toJson` is the established pattern (settings-backup, site-editing), and a global registry would need its own GC + import/export plumbing for no gain.

### D2. Resolution order

`LinkRoutingService.resolveOutbound(targetUrl, sourcePrefs, allSites)` returns one of `OutboundResolution.preference(targetSite)`, `OutboundResolution.global(RoutingMatch)`, or `OutboundResolution.selfMatch()`:

1. For each `OutboundPreference` in `sourcePrefs`, score against `targetUrl` using LIR-002's specificity table (`exactHost` 300, `wildcardSubdomain` 200, `baseDomain` 100). Pick the highest-scored entry whose `targetSiteId` still exists. Return `OutboundResolution.preference`.
2. If no preference matches, call existing `resolve(targetUrl, allSites)` and return `OutboundResolution.global(...)` with the underlying `RoutingSingle` / `RoutingAmbiguous` / `RoutingNone`.
3. **Self-match guard**: any resolved target whose `siteId == sourceSiteId` collapses to `OutboundResolution.selfMatch()`. This handles the edge case of a source site whose own claims cover the destination (DDG with `wildcardSubdomain(duckduckgo.com)` clicking a `links.duckduckgo.com` URL).

**Source-preference-wins rule**: a preference at any score beats a global LIR winner at any score. Rationale: the user wrote the preference *from this source's context*; that is a more specific signal than the global claim graph. The picker remember-checkbox path (D4) is the only way preferences get populated implicitly.

**Alternative considered**: tiebreaker semantics where global LIR wins when unambiguous and source prefs only break ties. Rejected — the user picked "source preference wins" up front, and the work-vs-personal-GitHub use case requires it.

### D3. Dispatch shape

`LinkIntentDispatchEngine.dispatchOutbound(...)` returns:

| Resolution | Action | Notes |
|------------|--------|-------|
| `preference(site)` | `DispatchOpenNested(siteId, url, sourceIsParent: true)` | Silent. |
| `global(RoutingSingle(site))` | `DispatchOpenNested(siteId, url, sourceIsParent: true)` | Silent. |
| `global(RoutingAmbiguous(sites))` | `DispatchShowPicker(winnerSiteIds: sites, offerCreate: false, offerBind: false, source: sourceSiteId)` | Picker only fires when source has launcher mode on. |
| `global(RoutingNone)` | `DispatchNestedFallback()` | Today's behaviour: source-settings nested. |
| `selfMatch` | `DispatchNestedFallback()` | Today's behaviour. |
| (launcher mode off) | `DispatchNestedFallback()` | Engine short-circuits before resolving. |

The new `sourceIsParent` flag on `DispatchOpenNested` toggles `_executeOpenNested` to **skip** `_maybeSwitchToAllForSite`. For inbound LIR-011 the existing behaviour (switch to "All") is preserved by passing `sourceIsParent: false` from inbound callers.

`DispatchShowPicker` gains:
- `offerBind: bool` — `false` for outbound so the picker hides the "send {host} to {site}" row.
- `offerCreate: bool` — already exists; outbound passes `false`.
- `source: String?` — when present, the picker shows a "Always use this when opening links from {sourceName}" checkbox below the winners list. When the user picks a winner with the box ticked, the picker returns a `_DispatchChoiceOpen` plus an `outboundRememberSource: sourceSiteId` flag that the executor uses to call `LinkRoutingService.claimsToAdoptHost(host)` and append the resulting prefs (deduped) to source's `outboundPreferences`.

`DispatchNestedFallback` is the sentinel "do exactly what `web_view_model.dart` would have done before this change". It carries no payload; the executor calls today's `launchUrl(...)` with source settings.

**Alternative considered**: collapse `DispatchOpenNested` and `DispatchNestedFallback` into one variant with a `useSourceSettings` flag. Rejected — the destination-settings vs source-settings distinction is semantically important (it's the whole point of the change) and the action types in `LinkIntentDispatchEngine` are already sealed-class shaped for distinct semantics.

### D4. Picker remember-checkbox writeback

`_DispatchPickerSheet` already returns a `_DispatchChoice` value. For outbound mode (`source != null`), the sheet:

1. Shows a `CheckboxListTile` "Always use this when opening links from {sourceName}" beneath the winners. Default checked (the user clicked a winner; remembering is the friction-reducing choice).
2. On winner-row tap, returns `_DispatchChoiceOpen(site: chosen, rememberSource: source ?? null if unchecked)`.
3. The executor branch in `_executeDispatchAction` (new `_executeOutboundDispatch`) writes back to source's `outboundPreferences` via `claimsToAdoptHost(targetHost)` filtered to entries not already present, persists `WebViewModel.toJson` via `_saveWebViewModels`, then proceeds with `DispatchOpenNested`.

The bind ("send to {site}") and create rows are suppressed because outbound is not the right context to mutate destination claims (the user is mid-browse, not setting up routing) or to auto-spawn a site (surprising).

### D5. Executor wiring in `_WebSpacePageState`

New method `_executeOutboundDispatch(DispatchAction, Uri, WebViewModel source, ...sourceLaunchArgs)`:

- `DispatchOpenNested(sourceIsParent: true)` → activate the destination's webview-config-shaped `launchUrl` call (using destination's `siteId`, `incognito`, `language`, `userScripts`, etc) but **skip** `_maybeSwitchToAllForSite`. The nested screen pushes; the drawer / current webspace is untouched.
- `DispatchShowPicker(source: ...)` → reuse `_showDispatchPicker`, branch on `outboundRememberSource`, write back, then recurse into `_executeOutboundDispatch` with the user's choice.
- `DispatchNestedFallback()` → call today's `launchUrl(...)` with source's args (identical to current `web_view_model.dart` behaviour). This is also the engine output when launcher mode is off, so the call sites in `web_view_model.dart` collapse to "always go through the engine".

The two call sites in `web_view_model.dart` (`blockOpenNested` from `shouldOverrideUrlLoading`, and `blockOpenNested` from `onUrlChanged`) both shift from direct `launchUrlFunc(...)` to a new closure `outboundLaunchFunc(targetUrl)` injected via `WebViewModel.getController(...)`. The closure builds the inbound launch args from source's fields, calls `dispatchOutbound`, and routes the result through `_executeOutboundDispatch`.

### D6. Webspace behaviour

Outbound hijack uses `sourceIsParent: true` → `_maybeSwitchToAllForSite` skipped. Rationale: the user is mid-browse in webspace X; hijacking should not silently relocate them. Back-gesture from the nested view returns to source in webspace X exactly as it would without this change. This intentionally differs from inbound LIR-011, where the user came from outside the app and the "Switch to All" snackbar makes the destination's existence discoverable.

### D7. Orphan GC for `targetSiteId`

Mirroring cookie secure storage and proxy password orphan cleanup:

- On startup, after `_loadWebViewModels`, walk every site's `outboundPreferences` and drop entries whose `targetSiteId` is not in `_webViewModels`.
- After `_deleteSite(targetSite)`, walk every other site and drop preferences pointing at the deleted siteId.
- After `_importSettings`, run the startup-style pass.

Persist via `_saveWebViewModels` when entries are dropped. No user notification — orphaned prefs are silent state, not configuration the user should be alerted about.

### D8. UI surface

Per-site settings screen gains a section between "Privacy" and "Notifications":

```
Outbound link routing
├─ [switch] Route outbound links to matching sites          (off by default)
└─ Preferences                                              (shown only when switch is on)
   ├─ [Claim chip editor] github.com → [▼ Work GitHub]
   ├─ [Claim chip editor] *.github.com → [▼ Work GitHub]
   └─ [+ Add preference]
```

The claim chip editor reuses `DomainClaimsEditor`'s row primitives. The target dropdown lists every other site (excluding `this`). Empty target dropdown disables the row.

Subtitle when the switch is off: "When on, clicks to other domains can route into the site that claims that domain". When on with empty prefs: "Falls back to the global routing rule. Add a preference to override for a specific domain".

### D9. Tests

Pure-Dart, fast:

- `test/link_routing_test.dart` (extend): `resolveOutbound` — source pref beats global single, source pref skipped if target site missing, global single returned when no source pref, ambiguous returned, self-match collapses to selfMatch.
- `test/link_intent_dispatch_engine_test.dart` (extend): `dispatchOutbound` — emits `DispatchNestedFallback` when launcher mode off, `DispatchOpenNested(sourceIsParent: true)` on single resolution, `DispatchShowPicker(offerBind: false, offerCreate: false, source: ...)` on ambiguous, `DispatchNestedFallback` on self-match.
- `test/web_view_model_test.dart` (extend): JSON round-trip of `routeOutboundLinks` and `outboundPreferences`; omission when default; legacy load without the fields.
- `test/outbound_preference_gc_test.dart` (new): orphan cleanup after delete, after import, on startup.
- `test/link_handling_settings_test.dart` (extend or sibling): `OutboundRoutingSection` widget — toggle gates editor visibility, dropdown lists only other sites, picker writeback round-trips through `_saveWebViewModels`.

Manual: smoke test DDG launcher mode on Android (gesture click on `github.com` result lands in the user's GitHub site with login intact), back-gesture returns to DDG.

## Risks / Trade-offs

- **[Risk] User enables launcher mode on a site that legitimately needs same-session nested context** (e.g. a CMS where an outbound link to an embedded report should keep CMS cookies). Mitigation: opt-in per site; user can disable. Documenting in the "Outbound link routing" subtitle.
- **[Risk] Source pref points at a deleted site between GC passes** (race: site deleted then immediate outbound click before persist). Mitigation: the engine's preference-lookup checks `targetSiteId` existence in the live `sites` list, not the persisted prefs; missing target falls through to global LIR.
- **[Risk] Picker fires mid-browse and surprises the user** even with launcher mode on. Mitigation: picker only on ambiguous global LIR (multiple sites claim the same host); the remember checkbox + default-checked behaviour trains it away after one tap.
- **[Risk] Back-stack semantics with nested-bound-to-destination feel off** when the user expects to be "in" their GitHub site after clicking a GitHub link. Mitigation: this is consistent with inbound LIR-011 cross-domain shares (they also open as nested with destination settings) and with how Android's "Open in app" handoff works. If users complain, a follow-on change can offer a "open in main view instead of nested" per-source setting.
- **[Trade-off] Outbound prefs are directional (`source → destination`), so changing destination claims doesn't auto-propagate the inverse**. Acceptable — preferences point at `siteId`, not at claims, so renaming a destination site or editing its claims doesn't invalidate prefs.
- **[Trade-off] Outbound resolution adds one resolver pass per cross-domain gesture**. Resolver is O(claims × sites); for the typical user (≤ 30 sites, ≤ 5 claims each) this is < 200 string comparisons per click. Not measured, not expected to matter; revisit if profiles show otherwise.

## Migration Plan

1. Data model + JSON migration (silent for users who never enable the toggle).
2. `resolveOutbound` + `dispatchOutbound` engine entry points + pure-Dart tests.
3. `_executeOutboundDispatch` executor + `outboundLaunchFunc` wiring in `web_view_model.dart`.
4. Per-site settings UI (toggle + preferences editor).
5. `_DispatchPickerSheet` source-mode + remember checkbox + writeback.
6. Orphan GC at the three existing cleanup sites.

Each step is independent. Rollback: data is preserved (the JSON fields stay in the model); the user-facing effect disappears when the toggle is removed from the settings screen.

## Open Questions

1. Should the per-site toggle be cloned on a *site-editing copy/duplicate*? Proposal: clone (the user's intent transfers with the source identity); revisit if it surprises in practice.
2. Should ambiguity picker fire even when the source has launcher mode off but a preference matches the target? Proposal: no — the toggle gates the whole feature. Without it, outbound clicks are byte-identical to today.
3. Should `outboundPreferences` round-trip via the QR-share / site-settings-qr flow? Proposal: yes for v1 — they're per-site state and the existing QR plumbing already serialises the full `WebViewModel.toJson`. Confirm against `site-settings-qr` spec at implementation time.
