# BUG-030 — A Tor site's isolation tag is lost before its proxy is resolved

Status: **open, narrowed.** `resolveEffectiveProxy` and
`ProxyManager.setProxySettings` take a required `siteId`, so no call site can
leave the tag out without saying so. A call that passes `siteId: null` with
the site's stored settings still falls back to the app-global tag.

**Spec:** [tor-proxy](../../openspec/changes/add-ios-tor-proxy/specs/tor-proxy/spec.md)
TOR-003, TOR-025; [proxy](../../openspec/specs/proxy/spec.md) PROXY-011, PROXY-013
**Related:** [BUG-014](014-per-site-setting-dropped-at-the-native-seam.md)
instance 3, the same symptom on Apple with the credential dropped natively

## Symptom

Two sites set to `TOR` load, each looks isolated in the UI, and both present
the same SOCKS credential, so tor puts them on one circuit and one exit.
Nothing fails.

## Root mechanism

A Tor site's isolation is the SOCKS username, and the resolver gets the tag
one of two ways: from a `siteId` argument, or from a copy of the settings
with the tag stamped in (`WebViewModel.outboundProxySettings`). Stored
settings plus no `siteId` resolves to `kTorAppGlobalTag` without a word.
Every path that resolves a site's stored settings has to remember the id.

**Invariant:** a Tor connection made for a site carries that site's tag.

## Fix attempts

1. **2026-10-04, 2340e77a (#667).** *What:* `setProxySettings` took a
   `siteId` and passed it to the resolver before expanding TOR for the
   process-wide rule; `process_wide_tor_isolation.test.js` required every
   call to name it. *Why:* Android without the router and Linux applied one
   rule with the app-global tag. *Why partial:* it covered the process-wide
   rule; the router's route table resolved stored settings with no id.

2. **2026-10-07, #680.** *What:* `siteId` became required on
   `resolveEffectiveProxy` and `setProxySettings`; `ProxyRouterEngine.buildRoutes`
   passes each route's site id. The two gate cases the required parameter
   proves were deleted. Regression test: "two Tor sites route under their own
   isolation tags (TOR-003)" in `test/proxy_router_engine_test.dart`. *Why:*
   under the router (Android, PROXY-013) every Tor site presented the
   app-global credential to the external tor. *Why partial:* `siteId: null`
   is a legal answer, and it is the right one for app-global traffic and for
   settings that already carry their tag; the type cannot tell those from a
   site's stored settings.

3. **2026-10-07, refactor/cuts (follow-up to #680).** *What:* the site's
   favicon in a webspace's site list, the title fetched when a site is added
   or edited, and the user-script source fetch from a site's settings passed
   the stored `proxySettings` to `UnifiedFaviconImage`, `getPageTitle` and
   `fetchUserScriptSource`; they now pass `outboundProxySettings` (the
   favicon through `UnifiedFaviconImage.site`, the constructor every other
   site icon uses). `test/js/outbound_proxy_tag.test.js` fails on
   `proxy: <x>.proxySettings` anywhere in `lib/` but the router table.
   *Why:* these fetches resolve their proxy with no `siteId`, so attempt 2's
   required parameter never reached them; each sent a Tor site's request down
   the app-global circuit. *Why partial:* the gate matches the named-argument
   spelling; a stored setting reaching an outbound API by another route
   (a local variable, a positional argument) still compiles.

## Known open gaps

- Stored and outbound settings are one type. A distinct type for settings
  that carry their tag, returned only by `outboundProxySettings` and taken by
  every outbound API (favicons, titles, user scripts, downloads, media
  artwork, icon export), would make the fallback unreachable for a site and
  retire `outbound_proxy_tag.test.js`.
