# Onion location

## Why

Some sites run the same service as a Tor onion service (Proton, the Tor
Project, DuckDuckGo, Facebook). A site whose traffic already goes through Tor
still loads its clearnet address, so every request leaves through an exit
relay, which sees the destination and, for plain http, the content. The onion
address keeps the whole path inside Tor.

Onion addresses are 56 random characters nobody checks by eye, and fake onion
lists are a common phishing route. So the question is who vouches for an
address. This change takes it only from the site itself: the `Onion-Location`
header, or its `<meta http-equiv>` form, on the site's own HTTPS response, as
Tor Browser's ".onion available" does. The site's certificate vouches for it;
no list, registry or third party is trusted.

Checked on 2026-11-14: `proton.me` and `torproject.org` send the header;
`duckduckgo.com` does not, so it is not covered here (see Out of scope).

## What Changes

- **A new `onion-location` capability.** While a site's route is Tor, the app
  asks the site's home address, through that route, whether it announces an
  onion address (ONION-001), keeps only a well formed v3 address (ONION-002),
  and asks the user once before using it (ONION-003).
- **An endpoint, not a claim.** Once accepted, a top-frame load of the
  announcing origin goes to the onion origin with the same path (ONION-004),
  decided after the routing decision as the HTTPS upgrade is (HTTPS-004). The
  onion origin counts as the site's own while it is the endpoint (ONION-005),
  derived from the site's posture and never written into the user's domain
  claims.
- **Fallback only by choice.** An onion that fails to load, fails TLS or
  says nothing for 30 seconds stays on its failure unless the user chose,
  per site, to fall back to the clearnet address (ONION-006, ONION-009). A
  silent fallback would send the page through an exit relay the user moved
  the site away from, so it is opt-in. Onion services are often down, and
  certificates on them lapse (the newest one in Certificate Transparency for
  Proton's onion expired on 2026-11-03), which is what the choice is for.
- **Off Tor, nothing** (ONION-007): no check, no rewrite, the onion not owned.
- **Kept with the site, not carried** (ONION-008): the learned address and the
  answer stay with the site and are left out of backups and QR shares; a new
  device learns and asks again. The site is rechecked whenever its clearnet
  origin loads anyway, else every 30 days, without asking again for the same
  address: the onion address is the service's key, so only a withdrawn or
  changed address matters.

### Why an endpoint rather than a domain claim

A claim alone changes only where links to the onion open; the site would keep
loading its clearnet address, so it buys nothing. And `domainClaims` is the
user's own configuration, carried in backups: learned data written into it
would outlive the announcement it came from, with nothing to show where it
came from. The onion host does need to count as the site's own while it is the
endpoint (its pages are otherwise cross-domain, and `SiteOrigins` compares
schemes, which an `http://` onion of an `https://` site would fail), so
ONION-005 derives that from the posture.

## Out of scope

- **Sites that do not announce.** A curated list (real-world-onion-sites) or a
  Certificate Transparency match (both certificates naming the same
  organization) could cover DuckDuckGo. Both trust something other than the
  site's own announcement, so they are a later change. A survey on 2026-11-19
  of real-world-onion-sites' 147 entries found 104 whose clearnet site
  announces the listed onion, 4 that announce a different one (RFE/RL
  regional sites pointing at the network's main onion), 25 that announce
  nothing (DuckDuckGo, the New York Times, Reddit) and 14 not reached: for
  the sites that announce, the list adds nothing this change does not learn.
- **Other hosts of the site.** Only the origin that announced is rewritten;
  `account.proton.me` is not, unless it announces its own.
- **Cookies.** A session on the clearnet host is not one on the onion host;
  the user signs in again there, in the same container.

## Impact

- New: `lib/services/onion_location.dart`: `OnionAddress` (a checked v3
  address), `OnionEndpoint` (the move and its way back), `SiteOnion` (what
  is saved) and `announcedEndpoint` (reading the header or the meta tag);
  a check through `OutboundProxy` beside it.
- `HttpsUpgradeEngine` takes the move onto the onion beside the https
  upgrade (`onionFor`, `onFirstLoad`, `deadlineFor`): one set of events, one
  fallback, armed only for a site whose user chose it. An onion host is never upgraded to https.
- `SiteField.onionLocation`, outside backups and QR; `SiteContainer.onion`,
  read by `webview.dart`, `SiteOrigins` and `NavigationBoundary` (a new
  required `onion:`, so no surface builds one without saying).
- One prompt (the offer) and one row on the site Network screen.
- Persisted format: one new site JSON key, `onionLocation`, read as absent
  when it has the wrong shape.
