## ADDED Requirements

### Requirement: BEHAV-003 - Outbound routing rows in the Link handling group

The Behaviour screen's "External links" choice (BEHAV-004) SHALL hold, directly under its row and indented, while "Open in the app" is selected, a "Route links to my sites" switch (`routeOutboundLinks`, link-intent-routing LIR-013) and, while that switch is on, a "Routing preferences" row that opens a screen listing the site's outbound preferences. Routing is an option of opening links in the app (LIR-014), so both rows are shown only while "Open in the app" is the selected option; picking another option hides them and keeps their stored values. The domain-claim editor stays last in the group, under the choice whose hint names it.

Both rows SHALL be shown whatever developer mode says: routing is not an experimental feature (DEVTOOLS-011), and the per-site switch, off by default, is its only gate.

The switch SHALL carry its explanation in a `HintButton` on its title row (HINT-001), not in a subtitle. Its subtitle SHALL name state only: while the legacy cookie engine is active the switch SHALL be disabled (`onChanged: null`) and subtitled "Needs per-site containers", since LIR-014 does not route there; otherwise it SHALL have no subtitle. The preferences row's subtitle SHALL be state-derived: the preference count, or "Global routing only" when the list is empty.

`routeOutboundLinks` and `outboundPreferences` SHALL ride `SiteBehaviourValues`, so both are in the settings screen's dirty-snapshot diff and are saved with the rest of site settings (BUG-006, EDIT-009). The domain-claim editor remains the only control on the screen that writes straight to the model. The preferences screen's target choices SHALL be the site's LIR-014 candidates other than the site itself.

The Behaviour row's summary (BEHAV-002) SHALL name the routing switch when it is on and the site is in the in-app mode, like any other switch.

#### Scenario: The routing rows need no developer mode

- **GIVEN** developer mode is off
- **AND** the site has `routeOutboundLinks` on and one routing preference
- **WHEN** the Behaviour screen opens
- **THEN** the routing switch shows on and the Routing preferences row counts one preference
- **AND** the Behaviour row's summary names the routing switch

#### Scenario: Routing is an option of opening links in the app

- **GIVEN** the Behaviour screen is open and the site is in the in-app mode
- **THEN** the "Link handling" group reads, in order: the External links dropdown, Route links to my sites indented under it, then the domain-claim editor
- **AND** the Routing preferences row appears under the routing switch only while the switch is on

#### Scenario: Another external-link mode hides the routing rows

- **GIVEN** the site has `routeOutboundLinks` on
- **WHEN** the user picks "Open in browser" or "Block"
- **THEN** neither the routing switch nor the Routing preferences row is shown
- **AND** `routeOutboundLinks` is still stored on, and picking "Open in the app" shows the switch on again

#### Scenario: Explanation lives behind the hint

- **GIVEN** the Behaviour screen on a device with container support
- **THEN** the routing switch has a `HintButton` whose title is the switch's own title
- **AND** the switch has no subtitle

#### Scenario: The legacy engine disables the switch

- **GIVEN** the device runs the legacy cookie engine
- **THEN** the routing switch has `onChanged: null`
- **AND** its subtitle reads "Needs per-site containers"

#### Scenario: A routing edit is part of the unsaved-changes check

- **GIVEN** the user turns Route links to my sites on and goes back to site settings
- **WHEN** they leave site settings without saving
- **THEN** the discard prompt appears, as for any other behaviour switch

#### Scenario: Preference targets stay on the site's side of the archive boundary

- **GIVEN** an app-tier site while an archive is open
- **WHEN** the user adds a routing preference
- **THEN** the target list offers every other app-tier site
- **AND** it offers neither the site itself nor any archive-tier site

#### Scenario: The Behaviour row names the routing switch

- **GIVEN** a site with only Route links to my sites on
- **THEN** the Behaviour row in site settings reads "Route links to my sites"
