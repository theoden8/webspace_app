# Lazy Webview Loading - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: LAZY-001 - On-Demand Loading

Webviews SHALL be created only when the user visits a site, EXCEPT for sites with `notificationsEnabled == true` which SHALL be auto-loaded on app startup so their page JS can fire notifications without waiting for the user to open them. Requires container mode (`_useContainers == true`); on legacy devices the notification toggle is hidden so this modification does not apply.

In container mode there are no domain-conflict restrictions (PROF-003), so all notification sites auto-load freely regardless of domain overlap.

Implementation: see the auto-load loop in `_restoreAppState` ([lib/main.dart](../../../../../lib/main.dart)) that adds every `notificationsEnabled` site index to `_loadedIndices` after the per-site models have been hydrated.

#### Scenario: App starts with multiple notification sites

**Given** container mode is active
**And** Site A (`slack.com`) has `notificationsEnabled` set to `true`
**And** Site B (`teams.microsoft.com`) has `notificationsEnabled` set to `true`
**And** Site C (`github.com/personal`) has `notificationsEnabled` set to `true`
**When** the app starts
**Then** Sites A, B, and C are all added to `_loadedIndices`
**And** all three webviews are created with their per-site containers
**And** all three begin executing JavaScript
**And** sites without `notificationsEnabled` remain as placeholders until visited

#### Scenario: Notification site auto-loads alongside manually visited site

**Given** container mode is active
**And** Site A (`slack.com`) has `notificationsEnabled` set to `true`
**And** the user manually visits Site B (`github.com`)
**When** both sites are loaded
**Then** both coexist in `_loadedIndices` with isolated profiles
**And** Site A continues running JavaScript in background
