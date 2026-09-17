# Enhanced Tracking Protection — site behaviour screen delta

## MODIFIED Requirements

### Requirement: ETP-017 - Privacy screen

Everything that decides what a site can learn SHALL live on one per-site
Privacy screen (`SitePrivacyScreen`), reached from a single row in site
settings. The screen SHALL present, in order: Incognito mode as a
prominent card; the umbrella as a second prominent card labeled "Tracking
Protection" with subtitle "Anti-fingerprinting + force tracker blocking";
a "Trackers and ads" group holding ClearURLs, DNS Blocklist, Content
Blocker, LocalCDN (Android only) and Third-party cookies; and a
"Fingerprinting" group holding the letterbox switch.

Subordinates SHALL render `onChanged: null` while the umbrella is on,
with `value: true` for ETP-002's four and `value: false` for third-party
cookies (ETP-024). Only the third-party cookies row SHALL caption the
forcing ("Forced off by Tracking Protection"): a locked switch already
reads as locked, and repeating the reason on all five rows displaced the
one fact those subtitles carry, which is whether a blocker's data has
been downloaded. Forcing something *off* is the direction a reader does
not predict, so that row keeps its note. The LocalCDN subordinate is
gated additionally by `LocalCdnService.instance.hasCache` — its effective
value is `(stored || umbrella) && hasCache`, since it has no effect
without a populated cache.

Incognito mode leads the screen and SHALL NOT be forced by the umbrella:
a block-list turning itself on costs the user nothing, whereas incognito
discards their session on every restart. Grouping is by topic; forcing is
reserved for settings whose worst case is a missing page element or a
closed tracking channel.

HTML caching SHALL NOT appear here. It decides whether a page is redrawn
from disk on a cold start, which is a behaviour of the app rather than
something a site learns; it lives with the other behaviour switches, on
the Behaviour screen (BEHAV-001).

The anti-fingerprinting note under the letterbox group SHALL render only
while the umbrella is on, since with it off nothing is being randomised.

The screen SHALL own no persistent state. `SiteSettingsScreen` keeps the
fields, the dirty-snapshot diff and the save path (BUG-006 / EDIT-009);
the screen reads a `SitePrivacyValues` and reports whole values back
through `onChanged`.

The Behaviour, Privacy and Permissions rows SHALL sit at the foot of site
settings under a "Site" heading, below the leaf controls, in that order
(BEHAV-002). They are the rows a reader visits deliberately; the
controls above are what they scroll past on the way to something else.

The Privacy row SHALL summarise the current posture without being opened:
"Tracking Protection on" while the umbrella is on, otherwise the names of
the enabled protections (at most two, then a "{count} more" overflow), or
"No protection enabled" when none is.

#### Scenario: Incognito leads, umbrella follows

**Given** the user opens the per-site Privacy screen
**Then** an Incognito mode switch is shown above the "Tracking
Protection" switch
**And** both are rendered above the ClearURLs / DNS Blocklist / Content
Blocker / LocalCDN / Third-party cookies switches

#### Scenario: Subordinates disabled while umbrella is on

**Given** the umbrella is on
**Then** the ClearURLs, DNS Blocklist, and Content Blocker switches show
`value: true`
**And** the LocalCDN switch shows `value: true` when
`LocalCdnService.instance.hasCache` is true (otherwise `false`, since
the cache is empty)
**And** the Third-party cookies switch shows `value: false`
**And** their `onChanged` is `null` (Material renders the switch grey)

#### Scenario: The forcing is captioned once, not five times

**Given** the umbrella is on
**Then** no "Forced on by Tracking Protection" subtitle is rendered
**And** the Third-party cookies row reads "Forced off by Tracking
Protection"
**And** the ClearURLs row keeps its own description

#### Scenario: Subordinates editable while umbrella is off

**Given** the umbrella is off
**Then** the five subordinate switches are tappable
**And** their values reflect the per-site stored booleans

#### Scenario: Incognito stays the user's own decision

**Given** the umbrella is on
**Then** the Incognito mode switch is still tappable
**And** its value reflects the per-site stored boolean

#### Scenario: Settings row summarises without opening

**Given** a site with the umbrella off and only ClearURLs enabled
**Then** the Privacy row in site settings reads "ClearURLs"
**And** with the umbrella on it reads "Tracking Protection on"
**And** with nothing enabled it reads "No protection enabled"
