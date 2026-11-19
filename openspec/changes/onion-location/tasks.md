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

- [ ] 4.1 The check: a GET of the home address through `model.outboundProxy`, redirects
  within the site's claims and over https only, the body read up to the end of `<head>`
  (ONION-001); run when the route becomes Tor, when the clearnet origin loads anyway
  (a fallback, a load the rewrite left), and on a load over Tor 30 days after the
  last check (ONION-008).
- [ ] 4.2 The offer, a `confirm()` naming the site and the address; the answer saved
  on the site (ONION-003). Code with `app_en.arb`; translations in their own commit.
- [ ] 4.3 A row on the site Network screen showing the address and its state, with a
  way to forget it.

## 5. Wire and verify

- [x] 5.1 `webview.dart`: the rewrite in `shouldOverrideUrlLoading` after the routing
  decision and before the HTTPS upgrade, and for the first load (ONION-004); fallback
  from the load error, the TLS rejection and the deadline, through the handlers the
  HTTPS upgrade already forwards (ONION-006). An onion host is never upgraded to https.
- [ ] 5.2 Archive-tier audit (ARCH-006): the new fields live in the site JSON, which
  the archive keeps under its key; nothing else touches disk.
- [ ] 5.3 Name each ONION requirement in its test and drop it from `unverified.tsv`.
