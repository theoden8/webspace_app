# Site Behaviour

## ADDED Requirements

### Requirement: BEHAV-001 — Behaviour screen

Everything that decides how the app hosts a site — as opposed to what the site
may learn (Privacy, ETP-017) or what it may reach (Permissions) — SHALL live on
one per-site Behaviour screen (`SiteBehaviourScreen`), reached from a single row
in site settings.

The screen SHALL present, in order: an "Opening and display" group holding
Always open Home, Kiosk mode, Full screen mode and HTML caching; then a "Link
handling" group holding Block auto-redirects, Open external links in browser,
and the site's domain-claim editor. The claims editor renders last in that
group because the external-links hint tells the reader to add domains there,
and a reader following that sentence should not have to leave the screen.

Always open Home SHALL render `value: true` with `onChanged: null`, subtitled
"Forced on by Incognito", while the site's `incognito` is on: incognito drops
the stored URL on every restart, so the site opens at its home page whatever
this switch stores. Incognito itself stays on the Privacy screen, and the
stored `alwaysOpenHome` SHALL be preserved so turning incognito off restores
the user's own choice.

The screen SHALL own no persistent state. `SettingsScreen` keeps the fields,
the dirty-snapshot diff and the save path (BUG-006 / EDIT-009); the screen
reads a `SiteBehaviourValues` and reports whole values back through
`onChanged`. The domain-claim editor is the one exception and SHALL be passed
in as a widget by the caller: it writes straight to the model rather than
through the value object, exactly as it did while it rendered inline, so it
stays with the screen that holds the model.

#### Scenario: Every behaviour switch is on the screen

**Given** the user opens the per-site Behaviour screen
**Then** Always open Home, Kiosk mode, Full screen mode, HTML caching, Block
auto-redirects and Open external links in browser are all shown
**And** none of them remains on the settings screen it was reached from

#### Scenario: The claims editor follows the switch that names it

**Given** the Behaviour screen is open
**Then** the domain-claim editor renders below Open external links in browser,
under the "Link handling" heading

#### Scenario: Incognito forces Always open Home

**Given** the site has `incognito` on
**Then** the Always open Home switch shows `value: true`
**And** its `onChanged` is `null` (Material renders the switch grey)
**And** its subtitle reads "Forced on by Incognito"

#### Scenario: Turning incognito off restores the stored choice

**Given** `alwaysOpenHome` is stored false and incognito is on
**When** incognito is turned off on the Privacy screen
**Then** the Always open Home switch is tappable again and reads false

#### Scenario: An edit survives until the settings screen saves it

**Given** the user toggles Kiosk mode on the Behaviour screen and goes back
**Then** the settings screen's snapshot diff sees the change
**And** leaving site settings without saving prompts to discard it

### Requirement: BEHAV-002 — Settings row summarises without opening

The Behaviour, Privacy and Permissions rows SHALL sit at the foot of site
settings under the "Site" heading, below the leaf controls, in that order.
Behaviour leads: it is what the app does with the site, and the two rows after
it are what the site is allowed to do.

The Behaviour row SHALL summarise its state without being opened: the names of
the switches that are on, at most two followed by a "{count} more" overflow, or
"Nothing enabled" when none is. Always open Home counts as on while incognito
forces it, since that is what the screen shows.

#### Scenario: The row names what is on

**Given** a site with Block auto-redirects on and nothing else
**Then** the Behaviour row in site settings reads "Block auto-redirects"

#### Scenario: More than two overflow

**Given** a site with Kiosk mode, Full screen mode and Block auto-redirects on
**Then** the row names two of them and then "1 more"

#### Scenario: Nothing on

**Given** a site with every behaviour switch off
**Then** the row reads "Nothing enabled"
