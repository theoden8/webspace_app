## ADDED Requirements

### Requirement: BEHAV-005 — Tabs on the Behaviour screen

While tabs are reachable (TAB-012), the "Opening and display" group SHALL show
a Tabs switch directly below Full screen mode, beside the switches that decide
how the site opens. The switch SHALL follow TAB-013: it reads
`effectiveTabsEnabled`, turning it on turns Kiosk mode off, and Kiosk mode on
shows it off while the stored choice is kept. Its hint SHALL say that it and
Kiosk mode exclude each other, and where Always open Home lands a site with
tabs (TAB-014). While tabs are not reachable the row SHALL NOT be shown.

The Behaviour row in site settings (BEHAV-002) SHALL NOT name Tabs: it is on by
default, so naming it would crowd every site's summary, and a site whose tabs
are off because it is a kiosk already names Kiosk mode.

#### Scenario: The row follows the experiment

- **GIVEN** the Site tabs switch is off
- **THEN** the Behaviour screen shows no Tabs switch
- **WHEN** developer mode and the Site tabs switch are on
- **THEN** the Tabs switch is shown below Full screen mode

#### Scenario: Kiosk mode shows tabs off

- **GIVEN** a site with Tabs on
- **WHEN** the user turns Kiosk mode on
- **THEN** the Tabs switch reads off
- **AND** the stored `tabsEnabled` is still on

#### Scenario: Full screen mode leaves tabs on

- **GIVEN** a site with Tabs on
- **WHEN** the user turns Full screen mode on
- **THEN** the Tabs switch still reads on

#### Scenario: Tabs on is not in the summary

- **GIVEN** a site with Tabs on and every other behaviour switch off
- **THEN** the Behaviour row reads "Nothing enabled"
