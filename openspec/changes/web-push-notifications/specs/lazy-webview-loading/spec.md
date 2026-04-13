# Lazy Webview Loading - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: LAZY-001 - On-Demand Loading

Webviews SHALL be created only when the user visits a site, EXCEPT for sites marked as background-active which SHALL be auto-loaded on app startup. Auto-loading respects domain-conflict rules: if two background-active sites share a second-level domain, only one can be loaded.

#### Scenario: App starts with background-active sites on distinct domains

**Given** Site A (`slack.com`) has `backgroundActive` set to `true`
**And** Site B (`teams.microsoft.com`) has `backgroundActive` set to `true`
**And** Site A and Site B have different second-level domains
**When** the app starts
**Then** both Site A and Site B are added to `_loadedIndices`
**And** both webviews are created and begin executing JavaScript
**And** non-background-active sites remain as placeholders until visited

#### Scenario: App starts with background-active sites on same domain

**Given** Site A (`github.com/personal`) has `backgroundActive` set to `true`
**And** Site B (`github.com/work`) has `backgroundActive` set to `true`
**And** both share the second-level domain `github.com`
**When** the app starts
**Then** only the first site (by list order) is auto-loaded
**And** the second site remains as a placeholder
**And** a warning is logged about the domain conflict

#### Scenario: Background-active site auto-loads alongside manually visited site

**Given** Site A (`slack.com`) has `backgroundActive` set to `true`
**And** the user manually visits Site B (`github.com`)
**When** both sites are loaded
**Then** both coexist in `_loadedIndices` (different domains, no conflict)
**And** Site A continues running JavaScript in background
