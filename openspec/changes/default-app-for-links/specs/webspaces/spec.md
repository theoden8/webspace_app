## MODIFIED Requirements

### Requirement: WEBSPACE-009 - "All" Webspace

The system SHALL provide a special "All" webspace that shows all sites. The "All" webspace SHALL additionally enforce claim-aware per-site cookie isolation (see `per-site-cookie-isolation` ISO-001 and ISO-012): two sites cannot be simultaneously active when their domain-claim sets (including `initUrl` base domain) intersect. Named user-created webspaces are unaffected by claim-aware isolation.

#### Scenario: View all sites via All webspace

**Given** the user has multiple webspaces with various sites
**When** the user selects the "All" webspace
**Then** all sites are displayed in the drawer
**And** the "All" webspace cannot be deleted or moved

#### Scenario: Claim-aware isolation in "All" webspace

**Given** the active webspace is "All"
**And** Site A claims `baseDomain:google.com`
**And** Site B claims `baseDomain:google.com`
**When** the user selects Site B
**Then** Site A is unloaded per cookie-isolation rules
**And** Site B is loaded

#### Scenario: Named webspace retains legacy isolation

**Given** the active webspace is a named webspace "Work"
**And** Sites A and B from the previous scenario are both members of "Work"
**When** the user selects Site B
**Then** Site A remains loaded
**And** both sites are active simultaneously

---

## ADDED Requirements

### Requirement: WEBSPACE-011 - Link Intent Routes into Current Webspace

When a URL arrives via share/open intent (see `link-intent-routing`), the matched site SHALL be activated within the currently selected webspace if it is a member; otherwise the system SHALL switch the active webspace to the default "All" webspace and then activate the matched site.

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
