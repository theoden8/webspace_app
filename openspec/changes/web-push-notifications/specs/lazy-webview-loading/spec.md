# Lazy Webview Loading - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: LAZY-001 - On-Demand Loading

Webviews SHALL be created only when the user visits a site, EXCEPT for sites marked as background-active which SHALL be auto-loaded on app startup.

#### Scenario: App starts with background-active sites

**Given** Site A has `backgroundActive` set to `true`
**And** Site A has not been manually visited this session
**When** the app starts
**Then** Site A's webview is created and added to `_loadedIndices`
**And** Site A begins executing JavaScript in the background
**And** non-background-active sites remain as placeholders until visited
