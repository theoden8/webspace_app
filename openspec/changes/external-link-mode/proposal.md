# External link mode

## Why

Issue #629 asks for a per-site setting that makes it impossible for a site to
take the user to another site, while images and other resources from other
domains keep loading. The per-site switch "Open external links in browser"
already chose between two destinations for a link leaving the site; a third,
"nowhere", does not fit a switch.

Outbound routing (`route-outbound-via-lir`) added a second switch beside it,
"Route links to my sites", whose effect depended on the first: a routed
destination beat the system browser, and an unrouted link fell back to
whichever of nested or browser the first switch picked. Routing answers which
site a link opens *in the app* as, so it belongs to the in-app choice.

## What Changes

- **`WebViewModel.externalLinkMode`** (`ExternalLinkMode.inApp` | `browser` |
  `block`, default `inApp`) replaces the `externalLinksInBrowser` bool. JSON
  key `externalLinkMode`, omitted at the default. `fromJson` reads the old
  `externalLinksInBrowser: true` as `browser` (BACKUP-012 rename).
  `effectiveExternalLinkMode` keeps the ARCH-006 override: archive-tier
  `browser` reads as `inApp`; `block` stays in force.
- **`NavigationDecision.blockOutbound`**: the navigation engine takes the mode
  instead of the bool. A claimed target still nests; an unclaimed one nests,
  goes to the browser, or is cancelled, by mode. The main webview hands a
  blocked link to the host hook so a tapped link shows a short "Link to
  {host} blocked" message; a gesture-less one is blocked silently. The nested
  screen applies the same mode against the page it shows (NESTED-009).
- **Routing is an option of the in-app mode.** `effectiveRouteOutboundLinks`
  is `routeOutboundLinks && externalLinkMode == inApp`; `routeOutbound` acts on
  `blockOpenNested` only. The browser fallback of routing
  (`OutboundFallback.external`, `DispatchOpenExternal`) is removed.
- **UI**: the Behaviour screen's switch becomes an "External links" row with a
  dropdown (Open in the app / Open in browser / Block), like the other
  multiple-choice settings, with its explanation behind a hint. The routing
  switch and its preferences row sit indented under it, and only while "Open
  in the app" is picked.
- **Auto-redirect blocking is no longer a setting.** Every site blocks
  gesture-less cross-domain navigations (NESTED-004); the per-site
  `blockAutoRedirects` switch, its field, its place in the nested chain and
  its strings are removed (NESTED-006 withdrawn). A stored value is ignored
  and retired from backups; a QR payload carrying it turns nothing off. The
  cost: a sign-in button that navigates to the identity provider by script,
  with no tap the platform reports, has no per-site workaround. On iOS and
  macOS that is any script navigation. The white-screen integration suite
  reaches its nested screen through the URL bar instead of a scripted hop.
- **Nested chain**: `externalLinkMode` replaces `externalLinksInBrowser` in
  `LaunchUrlFunc`, `launchUrl`, `InAppWebViewScreen` and both call sites.

## Capabilities

### Modified Capabilities

- `nested-url-blocking`: NESTED-009 becomes the three-way external link mode;
  NESTED-004 holds on every site and NESTED-006 is withdrawn.
- `site-behaviour`: BEHAV-001 and BEHAV-002 name the choice; BEHAV-004 adds it.
- `captcha-support` CAPTCHA-008, `per-site-cookie-isolation` ISO-013,
  `site-settings-qr` QR-008, `integration-tests` INTEG-010: stop naming the
  switch.
- `link-intent-routing` (in-flight change `route-outbound-via-lir`): LIR-013,
  LIR-014 and BEHAV-003 are edited in place so routing reads as an option of
  the in-app mode.

## Impact

- Code: `lib/settings/external_links.dart` (new), `navigation_decision_engine`,
  `web_view_model`, `main`, `inappbrowser`, `site_behaviour`, `settings`,
  `link_intent_dispatch_engine`, `external_url_prompt`, QR codec
  classification.
- Backups: `externalLinksInBrowser` is listed in the compat test's
  `_renamedKeys`; every release's `true` imports as `browser`.
- QR: `externalLinkMode` stays unshared, as its predecessor was.
- Migration: a site with the old switch on loads in the browser mode; one with
  it off, or without it, loads in the in-app mode. A site that had routing and
  the browser switch both on loads in the browser mode and stops routing; its
  routing switch comes back when it is put in the in-app mode.
- Known gap, unchanged from `blockAutoRedirects`: a cross-domain server
  redirect that reaches only `onUrlChanged` cannot be navigated back (the
  Chromium crash that removed the navigate-back), so the parent can show the
  redirect target until the next navigation. `shouldOverrideUrlLoading` sees
  taps and script navigations, which is the path the issue describes.
