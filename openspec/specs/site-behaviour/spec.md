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
handling" group holding the External links choice (BEHAV-004), Sign-in popups
where the platform offers them (nested-url-blocking NESTED-014) and the site's
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
indented, and only while the site explicitly selects "Open in the app". App
default SHALL hide both routing rows and inherit the app's routing choice as
well as its external-link mode. Picking another option SHALL preserve the
site's stored routing choice for a later return to explicit in-app links.

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

App Settings → Behaviour SHALL group its app defaults under "Opening and
navigation": Tabs (on initially),
External links (Open in the app initially), Route links to my sites (off
initially, shown under in-app links) and, where the platform offers them
(nested-url-blocking NESTED-014), Sign-in popups (on initially). New sites SHALL follow these live
defaults. The External links picker SHALL offer App default and explicit
choices. Routing SHALL be a plain on/off switch with no separate inheritance
state or reset gesture; it inherits only through External links → App default.
Tabs and Sign-in popups SHALL each use a switch that is slightly dimmed while
following the app and fully opaque for an explicit override. It SHALL remain
interactive in both states and show an App default subtitle while following.
Tapping SHALL create an explicit override. A long press SHALL move between
the two states without flipping the switch: on an override it clears it and
restores inheritance, and while following it keeps the value shown as the
site's own. It SHALL not also toggle on release. One control owns this rule
(`ScopedToggle`), so every switch that follows a default behaves alike. The
hint SHALL explain the gesture and accessibility semantics SHALL expose the
long-press action under the name of what it does next.
Restoring App default SHALL participate in the dirty edit
snapshot and persist through save, restart and backup. The inherited value
SHALL be visible without opening another screen. Changing the app default
SHALL affect following sites and preserve explicit overrides and open tabs.
Closing App Settings SHALL reconcile open link tabs with the live routing
choice, retaining their tab identities when their container changes.
Kiosk mode SHALL still disable tabs and archive restrictions SHALL still fold
browser links into the app after resolving inheritance. Routing SHALL apply
only in the site's resolved in-app mode and where the container engine offers
it. While External links explicitly selects Open in the app, the per-site
routing switch SHALL show its saved on/off choice, and the
routing-preferences row SHALL follow the resolved routing value. Following
the app's external-link policy SHALL hide both routing rows, use the app's
routing default and leave the site's stored routing override unchanged.

Persistence SHALL distinguish explicit null (follow app) from a missing key for
Tabs and External links in older data (Tabs on, links in-app, or browser for the
legacy true flag). Sign-in popups came after the per-site choices, so a missing
key follows the app and only an explicit choice is written. Routing SHALL store a boolean, defaulting to off for missing
or null values. New saves SHALL write all three keys, so a following site and an
explicit choice each survive restart and backup without becoming the other.

#### Scenario: Return to following the app

**Given** a site overrides Tabs on and External links to Block
**When** the user selects App default for both and saves
**And** changes the app defaults to Tabs off and Open in browser
**Then** the site runs with tabs off and browser links after a restart
**And** another site with explicit choices retains them

#### Scenario: Routing follows the app without discarding an override

**Given** a site follows the app's External links policy, which opens in the app
**When** the app routing default is enabled
**Then** the site routes links to its own sites and hides the routing controls
**When** the site explicitly selects Open in the app
**Then** its routing switch shows the saved boolean, off initially
**And** changing the app routing default does not change that explicit choice
**When** the site selects External links → App default again
**Then** routing follows the live app default and the routing controls disappear

#### Scenario: Long press restores the Tabs default

**Given** the app enables Tabs and a site explicitly disables them
**When** the user long presses the Tabs switch
**Then** the switch follows the app, is slightly dimmed and shows Tabs on
**And** releasing the press does not create another override
**When** the app disables Tabs
**Then** the following switch shows Tabs off
**When** the user taps it
**Then** it stores an explicit Tabs-on choice and is fully opaque

#### Scenario: Long press keeps the value a following switch shows

**Given** the app disables Tabs and a site follows it
**When** the user long presses the Tabs switch
**Then** the site stores an explicit Tabs-off choice
**And** the switch is fully opaque and still shows Tabs off
**When** the app enables Tabs
**Then** the site's switch still shows Tabs off

#### Scenario: A site keeps its own Sign-in popups choice

**Given** the app's Sign-in popups switch is on and a site follows it
**Then** the site's switch is slightly dimmed, shows on and says App default
**When** the user taps it off and saves
**Then** the site's JSON carries `signInPopups: false` and its webview declines sign-in windows
**When** the user long presses it
**Then** it follows the app again and the key is no longer written

#### Scenario: Inherited external links have no hidden routing override

**Given** a site explicitly opens links in the app with routing on
**And** the app defaults to in-app links with routing off
**When** the site selects App default for External links
**Then** both routing rows are hidden and routing follows the app default
**And** changing the app routing default updates the site while the rows stay hidden
**When** the site returns to explicit Open in the app
**Then** its saved routing-on choice and Routing preferences appear again

#### Scenario: Upgrade keeps prior behavior

**Given** an older site's JSON omits Tabs, External links and routing
**When** it loads with app defaults of Tabs off, Block and routing on
**Then** it retains explicit Tabs on, in-app links and routing off
**And** saves those choices explicitly

Validation: `test/behaviour_defaults_test.dart`,
`test/site_behaviour_screen_test.dart`, `test/settings_backup_compat_test.dart`.
