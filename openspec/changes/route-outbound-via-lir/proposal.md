## Why

When the user taps a cross-domain link inside a site (a GitHub link in DuckDuckGo's results), `NavigationDecisionEngine` returns `blockOpenNested` and `web_view_model.dart` pushes an `InAppWebViewScreen` with the **source** site's posture: DuckDuckGo's container, cookies, user scripts and proxy. With `externalLinksInBrowser` on, the link leaves for the system browser instead. Either way the user lands on GitHub signed out, although they already keep a GitHub site with their login.

LIR (`link-intent-routing`) already classifies an arbitrary URL against per-site `domainClaims` for inbound shares. The same resolver can decide which existing site is the right container for an outbound link. This change runs it on the outbound path, so a tap from a launcher-style site (DuckDuckGo, Google, Kagi, an HN front page) lands in the user's own site for that domain.

It is opt-in per source. Nesting today is silent and back-reversible; a picker or even a snackbar on every outbound link would regress launcher-style browsing. The toggle is off by default; turning it on for DuckDuckGo is a one-time act.

## What Changes

- **Per-site toggle** `WebViewModel.routeOutboundLinks` (default `false`). While it is off, outbound taps take exactly today's path.
- **Per-site preferences** `WebViewModel.outboundPreferences: List<OutboundPreference>`, each `(DomainClaim claim, String targetSiteId)`, so a source can settle which of several matching sites wins (work GitHub vs personal GitHub). A preference beats the global resolver.
- **When routing runs**: only with the experiment on (developer mode and its own switch in App settings > Developer > Experimental), only for a `blockOpenNested` or `blockOpenExternal` decision in the source's own webview, only for a navigation that carried a user gesture, and only on the container engine. `NavigationDecisionEngine` starts returning the gesture it already computes; its decisions do not change.
- **Resolution order**: source preferences (most specific claim first), then the global resolver over the candidates, with any result naming the source itself collapsing to "no destination". Candidates are the sites on the source's side of the archive boundary.
- **Composition with `externalLinksInBrowser`**: a resolved destination wins over the system browser; a link no candidate claims keeps the navigation engine's decision (nested with the source's posture, or the system browser).
- **Outbound dispatch** on `LinkIntentDispatchEngine`, `dispatchOutbound(...)`:
  - `DispatchOpenNested(siteId, url, sourceIsParent: true)`: open the destination nested through the existing `_executeOpenNested` path (PROXY-008 on Android and Linux, the NESTED-010 funnel), without switching webspace.
  - `DispatchShowPicker(...)` on a tie: the LIR-010 sheet in outbound mode, with an "Open without routing" row and a remember checkbox that writes a preference back to the source.
  - `DispatchNestedFallback` / `DispatchOpenExternal`: the call site's current behaviour, untouched.
- **Proxy on return**: when opening the destination flipped the process-global proxy (Android without router mode, Linux), back from its screen re-runs the source's activation before the source is shown.
- **GC** of preferences whose target is gone or across the archive boundary: at startup, after a delete, after an import, and on a move into or out of an archive.
- **Per-site UI** on the Behaviour screen's "Link handling" group: a "Route links to my sites" switch with its explanation behind a hint, and a "Routing preferences" row opening an editor. Disabled on the legacy engine.
- **Backup and QR**: both fields ride `WebViewModel.toJson` into backups; the QR share carries the toggle and never the preferences, which name device-local site ids.

### Explicitly out of scope

- Detecting launcher sites heuristically (`?q=`, `?query=`); the per-site toggle is honest and zero-config once set.
- Routing inside a nested screen: it navigates in place (NESTED-010). Script `window.open` is not a path either: `onCreateWindow` dismisses everything except captcha challenges (NESTED-013). `target="_blank"` anchors are covered, because NESTED-008 rewrites them into ordinary taps.
- Auto-creating a site for an unmatched outbound URL (LIR-010 option 3).
- A per-host exclusion list.

## Capabilities

### Modified Capabilities

- `link-intent-routing`: adds LIR-013 (per-site toggle and preferences), LIR-014 (when routing runs, candidates, resolution order, composition with external links), LIR-015 (routed open as nested with the destination's posture, no webspace switch, proxy restored on return), LIR-016 (picker in outbound mode, remember writeback, open without routing), LIR-017 (preference GC).
- `site-behaviour`: adds BEHAV-003 (the routing rows in the Link handling group).

`nested-url-blocking` keeps its requirements: `NavigationDecisionEngine` still owns whether a navigation leaves the source at all, and LIR only chooses where it lands.

## Impact

- **Flutter code**:
  - `WebViewModel`: `routeOutboundLinks`, `outboundPreferences`; an optional `onOutboundLink` hook consulted by the four `blockOpenNested` / `blockOpenExternal` branches in `getWebView`.
  - `lib/services/outbound_preference.dart`: the value type, the archive-boundary candidate rule (`OutboundBoundary`) and the prune (`OutboundPreferenceGc`).
  - `lib/services/navigation_decision_engine.dart`: `hadGesture` on its results.
  - `lib/services/link_routing_service.dart`: `resolveOutbound`.
  - `lib/services/link_intent_dispatch_engine.dart`: `routeOutbound` (the gates), `dispatchOutbound`, `pickOutbound`, `DispatchNestedFallback`, `DispatchOpenExternal`, `sourceIsParent`, picker `source` / `fallback`.
  - `lib/services/nested_open_engine.dart`: the proxy sequence and the return to the source around a nested open, shared with the inbound open.
  - `_WebSpacePageState`: the hook, `_executeOutboundDispatch`, the proxy return path, the picker's outbound mode, the prune at startup, delete and archive moves.
  - `lib/services/settings_import_engine.dart`: the prune on import, inside the plan.
  - `lib/widgets/dispatch_picker_sheet.dart`: the LIR-010 sheet, moved out of `main.dart` so its outbound mode can be widget-tested.
  - `lib/screens/site_behaviour.dart`, `lib/screens/settings.dart`, `lib/screens/link_handling_settings.dart`: the switch, the preferences row and `OutboundPreferencesScreen`.
  - `lib/services/site_settings_qr_codec.dart`: classification of the two keys.
- **Migration**: existing sites load with the toggle off and no preferences; serialization omits both. Nothing changes until the user turns the toggle on.
- **Tests**: resolver, dispatch engine, navigation gesture, model JSON, QR, GC, Behaviour screen, picker; a structural funnel test for the four branches.
- **Security**: routing needs a gesture, so a page cannot load a URL into another site's signed-in container by script. Preferences carry only `siteId` references and never cross the archive boundary.
- **Performance**: one resolver pass per routed gesture, O(claims x sites).
