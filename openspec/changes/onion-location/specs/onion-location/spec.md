# Onion location

## ADDED Requirements

### Requirement: ONION-001 - The onion address comes from the site itself

While a site's route is Tor, the app SHALL learn the site's onion address only
from the site's own `https://` response for its home address, fetched by the
app through the site's own route and Tor circuit: an `Onion-Location` response
header, else a `<meta http-equiv="onion-location" content="...">` in the
document's head. A redirect SHALL be followed only to a host the site's domain
claims cover, and only over https. No list, link, page script or plain-http
response SHALL supply an onion address.

#### Scenario: A site that announces its onion

**Given** a site at `https://proton.me` whose route is Tor
**And** its home page answers with `Onion-Location: https://protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion/`
**When** the site is checked
**Then** that onion address is learned for the site

#### Scenario: A plain-http answer is not trusted

**Given** a site at `http://example.com` whose route is Tor
**When** its home page answers with an `Onion-Location` header
**Then** nothing is learned

#### Scenario: A redirect away from the site is not followed

**Given** the home page redirects to a host the site's claims do not cover
**When** the site is checked
**Then** the check stops there and nothing is learned

---

### Requirement: ONION-002 - Only a well formed v3 address

An announced address SHALL be used only when it is an absolute `http` or
`https` URL whose host is a v3 onion address (56 base32 characters before
`.onion`, version byte 3, and the checksum the address carries matching the
SHA3-256 checksum of its key), on the scheme's default port. Anything else
SHALL be ignored, as if nothing were announced.

#### Scenario: A mistyped address is ignored

**Given** a site announces an onion address with one character changed
**When** the site is checked
**Then** the checksum does not match and nothing is learned

#### Scenario: A v2 address is ignored

**Given** a site announces a 16-character onion address
**Then** nothing is learned

---

### Requirement: ONION-003 - The user is asked once per address

A newly learned onion address SHALL NOT be used until the user accepts it, in
a prompt that names the site and the onion address. Declining SHALL be
remembered for that address, which is not offered again. A different address
announced later SHALL be offered on its own, and the old one stops being used
until the new one is answered. A check whose answer announces nothing SHALL
forget the learned address and its answer; a check that fails SHALL keep them.

#### Scenario: Accepting the address

**Given** an onion address is learned for a site
**When** the user accepts it
**Then** the site uses it as its endpoint while its route is Tor (ONION-004)

#### Scenario: Declining is remembered

**Given** the user declined a site's onion address
**When** the site announces the same address again
**Then** the user is not asked again

#### Scenario: The site stops announcing

**Given** a site's onion address was accepted
**When** a later check succeeds and the answer carries no announcement
**Then** the address and its answer are forgotten and the site loads its clearnet address

---

### Requirement: ONION-004 - The accepted onion is the site's endpoint on Tor

While a site's route is Tor and its onion address is accepted, a top-frame
navigation of any webview that runs as the site to the announcing origin
(scheme, host and port exactly) SHALL load the same path, query and fragment
on the onion origin instead. The rewrite SHALL be decided after the
navigation's routing decision, as the HTTPS upgrade is (HTTPS-004), and before
the HTTPS upgrade, so a plain-http clearnet URL goes to the onion rather than being upgraded
first. Sub-frames, sub-resources and other hosts SHALL NOT be rewritten.

#### Scenario: The home page loads from the onion

**Given** a site at `https://proton.me/mail` whose onion address is accepted and whose route is Tor
**When** the site loads
**Then** `https://protonmailrmez3lotccipshtkleegetolb73fuirgj7r4o4vfu7ozyd.onion/mail` is loaded

#### Scenario: Another host of the site is left alone

**Given** the same site
**When** the top frame navigates to `https://account.proton.me/login`
**Then** that URL loads unchanged

---

### Requirement: ONION-005 - The onion origin is the site's own while it is the endpoint

While a site's onion address is its endpoint (ONION-004), the onion origin, on
its own scheme, SHALL count as one of the site's own origins wherever the
site's origins are decided: its domain claims as the routing reads them, its
navigation boundary and `SiteOrigins`. It SHALL be derived from the site's
posture and SHALL NOT be written into the user's domain claims.

#### Scenario: A grant answers for the onion page

**Given** a site whose onion address is its endpoint
**When** a page on the onion origin asks for the camera
**Then** the request stands as the site's own, as it would on the clearnet origin

#### Scenario: The claims the user edits are unchanged

**Given** a site whose onion address is accepted
**When** the user opens the site's domain claims
**Then** the onion host is not among them

---

### Requirement: ONION-006 - A failing onion falls back only where the user chose it

When a navigation rewritten to the onion origin fails to load, is rejected by
TLS, or has no answer from the server within 30 seconds, what follows SHALL be
the site's fallback choice (ONION-009):

- **None**: the failure SHALL stay on screen as any failed load does, a TLS
  rejection SHALL reach the trust prompt as any other, no deadline SHALL be
  armed, and the next navigation to the announcing origin SHALL be rewritten
  again.
- **Clearnet**: the app SHALL load the clearnet URL it rewrote, with no trust
  prompt for the onion host, and SHALL NOT rewrite to that onion origin again
  in the same run. This state SHALL be kept in memory only.

#### Scenario: The onion is down, no fallback

**Given** a site whose onion address is its endpoint, with no fallback
**When** the onion load fails
**Then** the failure shows and nothing is loaded through an exit
**And** the next navigation to the clearnet origin goes to the onion again

#### Scenario: The onion is down, falling back

**Given** a site whose onion address is its endpoint, falling back to clearnet
**When** the onion load fails
**Then** the clearnet URL loads
**And** later navigations in the same run are not rewritten

#### Scenario: A lapsed certificate on the onion, falling back

**Given** the onion service presents an expired certificate, and the site falls back to clearnet
**When** the rewritten navigation is rejected by TLS
**Then** the clearnet URL loads without a trust prompt for the onion host

---

### Requirement: ONION-007 - Off Tor, nothing

While a site's route is not Tor, the app SHALL NOT check the site for an onion
address, SHALL NOT rewrite any navigation, and SHALL NOT count the onion origin
as the site's own. The learned address and its answer SHALL be kept, so the
site takes them up again when its route is Tor once more.

#### Scenario: The user turns Tor off

**Given** a site whose onion address is its endpoint
**When** the user sets the site's proxy to none
**Then** the site loads its clearnet address and no check runs

---

### Requirement: ONION-008 - Kept with the site, rechecked without asking

The learned onion address, when it was last checked and the user's answer
SHALL be saved with the site and SHALL be left out of a settings backup and a
QR share. A value of the wrong type in the saved site SHALL read as absent.

The site SHALL be checked again, through its route, when its clearnet origin
is loaded anyway (a fallback under ONION-006, or a top-frame load the rewrite
left alone), and otherwise when its last successful check is more than 30
days old. A recheck that finds the same address SHALL NOT ask again; only a
different address is offered (ONION-003). The onion address is the onion
service's key, so a changed certificate on the onion is no reason to ask.

#### Scenario: A restored site asks again

**Given** a backup made from a site whose onion address was accepted
**When** the backup is imported on another device
**Then** the site carries no onion address until it is checked and the user answers

#### Scenario: A recheck finds the same address

**Given** a site whose onion address was accepted 31 days ago
**When** the site loads over Tor and the check finds the same address
**Then** the user is not asked and the check date moves to today

#### Scenario: A fallback rechecks

**Given** a site whose onion load just fell back to its clearnet address
**When** the clearnet page loads
**Then** the site is checked again, and a withdrawn address is forgotten (ONION-003)

---

### Requirement: ONION-009 - The fallback is the user's explicit choice

A site's onion address SHALL carry a fallback choice, None or Clearnet, which
SHALL be None until the user picks Clearnet on the site's Network screen, and
SHALL be saved with the learned address (ONION-008). A saved address with no
choice SHALL read as None.

#### Scenario: A new onion address does not fall back

**Given** the user accepts a site's onion address
**When** the onion fails to load
**Then** the failure shows, as ONION-006 says for None

#### Scenario: The user opts into the fallback

**Given** a site whose onion address is accepted
**When** the user picks Clearnet as its fallback on the site's Network screen
**Then** a failed onion load goes to the clearnet URL from then on
