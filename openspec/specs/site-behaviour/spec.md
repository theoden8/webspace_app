# site-behaviour Specification

## Purpose
TBD - created by archiving change site-behaviour. Update Purpose after archive.

## Requirements

### Requirement: BEHAV-001 — Behaviour screen

Everything that decides how the app hosts a site — as opposed to what the site
may learn (Privacy, ETP-017) or what it may reach (Permissions) — SHALL live on
one per-site Behaviour screen (`SiteBehaviourScreen`), reached from a single row
in site settings.

The screen SHALL present, in order: an "Opening and display" group holding
Always open Home, Kiosk mode, Full screen mode and HTML caching; then a "Link
handling" group holding the External links choice (BEHAV-004) and the site's
domain-claim editor. There is no Block auto-redirects switch: every site
blocks gesture-less cross-domain navigations (nested-url-blocking NESTED-004). The claims editor renders last
in that group because the External links hint tells the reader to add domains
there, and a reader following that sentence should not have to leave the
screen.

HTML caching SHALL be absent where the engine cannot load a page from its
cache first (`engineLoadsCacheFirst`: Linux's WPE has no per-load cache
policy, webview-pause-lifecycle PAUSE-033), and the Behaviour row's summary
SHALL not name it there. The stored value is kept, so a backup or a QR
share carries it to a device where it applies.

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
**Then** Always open Home, Kiosk mode, Full screen mode and HTML caching are
shown as switches, and External links as a choice
**And** where the engine cannot load cache first, HTML caching is not shown
**And** none of them remains on the settings screen it was reached from

#### Scenario: The claims editor follows the switch that names it

**Given** the Behaviour screen is open
**Then** the domain-claim editor renders below the External links choice,
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

The Behaviour, Network, Privacy and Permissions rows SHALL sit at the foot of
site settings under the "Site" heading, below the leaf controls, in that
order. Behaviour leads and Network follows (NET-002): they are what the app
does with the site and how it carries its traffic, and the two rows after them
are what the site is allowed to do.

The Behaviour row SHALL summarise its state without being opened: the names of
the switches that are on, at most two followed by a "{count} more" overflow, or
"Nothing enabled" when none is. Always open Home counts as on while incognito
forces it, since that is what the screen shows. The External links choice
counts as on outside its default: "Open external links in browser" in the
browser mode, "Block external links" in the block mode.

#### Scenario: The rows keep their order

**Given** the user opens site settings
**Then** the rows under "Site" read Behaviour, Network, Privacy, Permissions,
top to bottom

#### Scenario: The row names what is on

**Given** a site with Kiosk mode on and nothing else
**Then** the Behaviour row in site settings reads "Kiosk mode"

#### Scenario: The row names a blocking site

**Given** a site with nothing else on and External links set to Block
**Then** the Behaviour row reads "Block external links"

#### Scenario: More than two overflow

**Given** a site with Kiosk mode, Full screen mode and HTML caching on
**Then** the row names two of them and then "1 more"

#### Scenario: Nothing on

**Given** a site with every behaviour switch off and External links set to
Open in the app
**Then** the row reads "Nothing enabled"

---

### Requirement: BEHAV-004 — External links choice

The "Link handling" group SHALL present the site's `externalLinkMode`
(nested-url-blocking NESTED-009) as one row titled "External links" whose
trailing control is a dropdown, like the other multiple-choice settings
(WebRTC policy, proxy type), offering in this order "App default", "Open in the app"
(`inApp`), "Open in browser" (`browser`) and "Block" (`block`). The stored
mode SHALL be the selected item, and picking one SHALL report the whole value
back through `onChanged`, so the edit joins the settings screen's
dirty-snapshot diff (BUG-006).

The row SHALL carry the explanation in a `HintButton` whose title is the row's
own title (HINT-001). While following the app, its subtitle SHALL show the
resolved mode; explicit choices SHALL have no subtitle. What each option does
lives in the hint.

Outbound routing's rows (BEHAV-003) SHALL render directly under the row,
indented, and only while the resolved mode is "Open in the app". Picking another
option hides them and keeps their stored values.

#### Scenario: The stored option is selected

**Given** a site stored in the `block` mode
**When** the Behaviour screen opens
**Then** the External links dropdown offers App default, Open in the app, Open in browser
and Block, with Block selected

#### Scenario: Picking an option reports the whole value

**Given** the Behaviour screen for a site with Kiosk mode on
**When** the user picks Block from the dropdown
**Then** `onChanged` receives a value with `externalLinkMode == block` and
Kiosk mode still on

#### Scenario: Explanation lives behind the hint

**Given** the Behaviour screen is open with an explicit External links choice
**Then** the External links row has a `HintButton` titled "External links"
**And** the row has no subtitle


### Requirement: BEHAV-007 — App defaults with per-site choices

App Settings → Behaviour SHALL offer app defaults for Tabs (on initially) and
External links (Open in the app initially). New sites SHALL follow these live
defaults. Both per-site pickers SHALL offer App default and explicit choices;
choosing App default SHALL clear the override, participate in the dirty edit
snapshot and persist through save, restart and backup. The inherited value
SHALL be visible without opening another screen. Changing the app default
SHALL affect following sites and preserve explicit overrides and open tabs.
Kiosk mode SHALL still disable tabs and archive restrictions SHALL still fold
browser links into the app after resolving inheritance.

Persistence SHALL distinguish explicit null (follow app) from a missing key in
older data (Tabs on, links in-app, or browser for the legacy true flag). New
saves SHALL write both keys, including null, so a following site and an
explicit choice each survive restart and backup without becoming the other.

#### Scenario: Return to following the app

**Given** a site overrides Tabs on and External links to Block
**When** the user selects App default for both and saves
**And** changes the app defaults to Tabs off and Open in browser
**Then** the site runs with tabs off and browser links after a restart
**And** another site with explicit choices retains them

#### Scenario: Upgrade keeps prior behavior

**Given** an older site's JSON omits Tabs and External links
**When** it loads with app defaults of Tabs off and Block
**Then** it retains explicit Tabs on and in-app links
**And** saves those choices explicitly

Validation: `test/behaviour_defaults_test.dart`,
`test/site_behaviour_screen_test.dart`, `test/settings_backup_compat_test.dart`.
