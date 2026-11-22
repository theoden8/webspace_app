## 1. Specify

- [x] 1.1 Write `specs/onion-location/spec.md`: ONION-001 to ONION-008.
- [x] 1.2 List ONION-001 to ONION-008 in `openspec/unverified.tsv` until their checks land.
- [x] 1.3 Add the `onion-location` row to the OpenSpec table in `CLAUDE.md`, marked *(change)*.

## 2. Values and engine

- [x] 2.1 `OnionAddress` (`lib/services/onion_location.dart`): an extension type made only
  by `OnionAddress.ofHost`, which checks length, version and the SHA3-256 checksum
  (pointycastle). Test with the Proton, DuckDuckGo and Tor Project addresses and planted
  one-character changes (ONION-002).
- [x] 2.2 `announcedEndpoint` and `OnionEndpoint.rewrite` (`lib/services/onion_location.dart`)
  read the header, else the meta tag (ONION-001, ONION-002), and move the announcing
  origin (ONION-004). The move and its fallback on failure, TLS rejection and the
  30-second deadline are `HttpsUpgradeEngine`'s (`onionFor`, `onFirstLoad`, ONION-006):
  the same events resolve both, so the onion takes no second state machine.

## 3. Site state

- [x] 3.1 `SiteField` cases for the learned address with its date and the answer, both
  `backup: false` and QR withheld (ONION-008); read arms that take a wrong type as absent.
- [x] 3.2 `SiteContainer.onion`, resolved by `WebViewModel.onionEndpoint`: set only when
  the route is Tor (`OutboundProxy.carriesTor`) and the address is accepted (ONION-004,
  ONION-007); a saved onion URL starts on the clearnet origin off Tor (`SiteOnion.startUrl`).
- [x] 3.3 `SiteOrigins` and `NavigationBoundary` take the endpoint's origin on its own
  scheme (ONION-005); the user's `domainClaims` stay untouched, since the editors copy
  `effectiveDomainClaims` back into them.

## 4. Check and prompt

- [x] 4.1 The check (`checkOnionLocation`, `lib/services/onion_location_check.dart`): a GET
  of the home address through `model.outboundProxy`, each redirect hop held to the site's
  claims and to https by `followPageSteered`, the body read up to the end of `<head>`
  (ONION-001). When it runs and what its answer does is `onion_location_engine.dart`'s
  (`onionCheckDue`, `learnFrom`): once a run, on the first page a site loads over Tor
  (`SiteHooks.firstPageLoaded`), on the onion only after 30 days (ONION-007, ONION-008).
- [x] 4.2 The offer (`OnionLocationController`, `DialogOnionPrompts`): `choose` naming the
  site and the address while the site is on screen; a dismissal answers nothing; accepting
  rebuilds the site's webview through `SiteResetController.settingsSaved` (ONION-003).
  Code with `app_en.arb`; translations in their own commit.
- [x] 4.3 The site Network screen: the address with a switch to use it, and, while used,
  the fallback choice, None first (ONION-009), carried in `NetworkChoices` so the dirty
  snapshot and the save cover them.
## 5. Wire and verify

- [x] 5.1 `webview.dart`: the rewrite in `shouldOverrideUrlLoading` after the routing
  decision and before the HTTPS upgrade, and for the first load (ONION-004); fallback
  from the load error, the TLS rejection and the deadline, through the handlers the
  HTTPS upgrade already forwards (ONION-006). An onion host is never upgraded to https.
- [x] 5.2 Archive-tier audit (ARCH-006): no override needed. The learned address and the
  answers live in the site JSON, which an archive seals under its key; the check is a
  request on the site's own route; the offer is an in-app dialog; nothing new is logged.
- [x] 4.4 `OnionFallback` on `SiteOnion`, carried to the engine as `OnionRoute`: with
  None the move puts nothing in flight and arms no deadline, so a failure is the page's
  (ONION-006).
- [x] 5.3 Name each ONION requirement in its test and drop it from `unverified.tsv`.
