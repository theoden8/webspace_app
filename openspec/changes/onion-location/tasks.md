## 1. Specify

- [x] 1.1 Write `specs/onion-location/spec.md`: ONION-001 to ONION-008.
- [x] 1.2 List ONION-001 to ONION-008 in `openspec/unverified.tsv` until their checks land.
- [x] 1.3 Add the `onion-location` row to the OpenSpec table in `CLAUDE.md`, marked *(change)*.

## 2. Values and engine

- [ ] 2.1 `OnionAddress` (`lib/services/onion_address.dart`): an extension type made only
  by `OnionAddress.parse`, which checks length, version and the SHA3-256 checksum
  (pointycastle). Test with the Proton, DuckDuckGo and Tor Project addresses and planted
  one-character changes (ONION-002).
- [ ] 2.2 `OnionLocationEngine` (`lib/services/onion_location_engine.dart`), pure:
  `announced(response)` reads the header, else the meta tag (ONION-001, ONION-002);
  `rewrite(url, endpoint:)` (ONION-004); fallback on failure, TLS rejection and the
  30-second deadline, in memory (ONION-006). Modelled on `HttpsUpgradeEngine`.

## 3. Site state

- [ ] 3.1 `SiteField` cases for the learned address with its date and the answer, both
  `backup: false` and QR withheld (ONION-008); read arms that take a wrong type as absent.
- [ ] 3.2 A `SitePosture` field for the endpoint, resolved in `WebViewModel.sitePosture`:
  set only when the route is Tor and the address is accepted (ONION-004, ONION-007).
- [ ] 3.3 `SiteOrigins` and the claims the routing reads take the endpoint's origin on
  its own scheme (ONION-005); the user's `domainClaims` stay untouched.

## 4. Check and prompt

- [ ] 4.1 The check: a GET of the home address through `model.outboundProxy`, redirects
  within the site's claims and over https only, the body read up to the end of `<head>`
  (ONION-001); run when the route becomes Tor and on a load over Tor when the last
  check is over 7 days old (ONION-008).
- [ ] 4.2 The offer, a `confirm()` naming the site and the address; the answer saved
  on the site (ONION-003). Code with `app_en.arb`; translations in their own commit.
- [ ] 4.3 A row on the site Network screen showing the address and its state, with a
  way to forget it.

## 5. Wire and verify

- [ ] 5.1 `webview.dart`'s `shouldOverrideUrlLoading`: the rewrite after the routing
  decision and before the HTTPS upgrade (ONION-004); fallback from the load error,
  the TLS rejection and the deadline (ONION-006).
- [ ] 5.2 Archive-tier audit (ARCH-006): the new fields live in the site JSON, which
  the archive keeps under its key; nothing else touches disk.
- [ ] 5.3 Name each ONION requirement in its test and drop it from `unverified.tsv`.
