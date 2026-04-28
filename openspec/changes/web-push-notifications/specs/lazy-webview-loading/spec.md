# Lazy Webview Loading - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: LAZY-001 - On-Demand Loading

Webviews SHALL be created only when the user visits a site, EXCEPT for sites marked as background-active which SHALL be auto-loaded on app startup. Requires profile mode (`_useProfiles == true`); on legacy devices `backgroundActive` is not available so this modification does not apply.

In profile mode there are no domain-conflict restrictions (PROF-003), so all background-active sites auto-load freely regardless of domain overlap.

#### Scenario: App starts with multiple background-active sites

**Given** profile mode is active
**And** Site A (`slack.com`) has `backgroundActive` set to `true`
**And** Site B (`teams.microsoft.com`) has `backgroundActive` set to `true`
**And** Site C (`github.com/personal`) has `backgroundActive` set to `true`
**When** the app starts
**Then** Sites A, B, and C are all added to `_loadedIndices`
**And** all three webviews are created with their per-site profiles
**And** all three begin executing JavaScript
**And** non-background-active sites remain as placeholders until visited

#### Scenario: Background-active site auto-loads alongside manually visited site

**Given** profile mode is active
**And** Site A (`slack.com`) has `backgroundActive` set to `true`
**And** the user manually visits Site B (`github.com`)
**When** both sites are loaded
**Then** both coexist in `_loadedIndices` with isolated profiles
**And** Site A continues running JavaScript in background
