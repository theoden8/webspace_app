## ADDED Requirements

### Requirement: WEBSPACE-011 - Link Intent Routes into Current Webspace

When a URL arrives via share/open intent or `webspace://open?url=...` (see `link-intent-routing`), the matched site SHALL be activated within the currently selected webspace if it is a member; otherwise the system SHALL switch the active webspace to the default "All" webspace and then activate the matched site, surfacing a snackbar that explains the switch.

#### Scenario: Matched site belongs to current webspace

**Given** the user is on the "Work" webspace containing Site A
**When** a URL arrives that the resolver matches to Site A
**Then** Site A is activated inside "Work"
**And** the active webspace does not change

#### Scenario: Matched site is not in current webspace

**Given** the user is on the "Work" webspace not containing Site B
**When** a URL arrives that the resolver matches to Site B
**Then** the active webspace switches to "All"
**And** Site B is activated
**And** a snackbar reads "Switched to All to open <url> in <Site B>"

#### Scenario: No-match recovery preserves current webspace

**Given** the user is on the "Work" webspace
**When** a URL arrives that does not match any site and the user accepts the "Create site?" prompt
**Then** the new site is added to the global site list
**And** the active webspace remains "Work" (the newly created site is not auto-added to "Work"; the user can edit the webspace later to include it)
