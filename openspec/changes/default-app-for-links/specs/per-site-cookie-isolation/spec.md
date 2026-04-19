## MODIFIED Requirements

### Requirement: ISO-001 - Mutual Exclusion

Only ONE webview per conflict key SHALL be active at a time. The conflict key SHALL be computed as follows:

- When the active webspace is the default "All" webspace (`__all_webspace__`): the conflict key of a site is the set `{getBaseDomain(initUrl)} ∪ {getBaseDomain(claim.value) for every claim in domainClaims}`. Two sites conflict if their conflict-key sets intersect.
- When the active webspace is any named (user-created) webspace: the conflict key is `getBaseDomain(initUrl)` only (legacy behavior, unchanged).

#### Scenario: Activate site on occupied base domain in "All" webspace

**Given** Site A (`github.com/personal`) is currently active in the "All" webspace
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's webview is disposed
**And** Site B's webview is created

#### Scenario: Claim-overlap conflict in "All" webspace

**Given** the active webspace is "All"
**And** Site A has `initUrl=https://google.com` (synthesized claim `baseDomain:google.com`)
**And** Site B has `initUrl=https://gmail.com` plus claim `baseDomain:google.com`
**When** Site B is activated
**Then** Site A is unloaded
**And** Site B is loaded
**And** a snackbar informs the user that Site A was unloaded due to claim overlap

#### Scenario: Claim overlap in named webspace does not trigger conflict

**Given** the active webspace is a named webspace containing Sites A and B from the previous scenario
**When** Site B is activated
**Then** Site A remains loaded
**And** both sites are active simultaneously (legacy behavior preserved)

---

## ADDED Requirements

### Requirement: ISO-012 - Claim-Based Conflict Detection in "All" Webspace

When the active webspace is "All", the system SHALL use each site's full domain-claim list in addition to its `initUrl` base domain when computing conflicts. The expanded conflict key SHALL be recomputed whenever claims are edited.

#### Scenario: Edit claims updates conflict detection

**Given** the active webspace is "All"
**And** Sites A (`github.com`) and C (`gitlab.com`) are both loaded
**When** the user edits Site C to add claim `baseDomain:github.com`
**Then** the editor rejects the change (see LIR-003 hijack-block)
**And** no unload happens

#### Scenario: Non-conflicting claim edit leaves other sites loaded

**Given** the active webspace is "All"
**And** Sites A (`github.com`) and C (`gitlab.com`) are both loaded
**When** the user edits Site A to add claim `exactHost:api.github.com`
**Then** no other site conflicts with the new claim
**And** both sites remain loaded

---

### Requirement: ISO-013 - Claim-List Persistence

The system SHALL persist each site's `domainClaims` list as part of `WebViewModel` JSON. The field SHALL be omitted when it equals the legacy-synthesized default (one `baseDomain` claim equal to `getBaseDomain(initUrl)`) to avoid churn for users who never touch the feature.

#### Scenario: User-defined claims persist across restart

**Given** the user saved claims `[exactHost:google.com, wildcardSubdomain:google.com]` on a site
**When** the app is restarted
**Then** the site's `domainClaims` list loads exactly as saved

#### Scenario: Legacy site stays serialization-stable

**Given** a site whose `domainClaims` equals the synthesized legacy default
**When** the site is serialized to JSON
**Then** the `domainClaims` field is omitted from the output
