# Per-Site Cookie Isolation - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: ISO-001 - Mutual Exclusion

Only ONE webview per second-level domain SHALL be active at a time. Background-active sites on a conflicting domain SHALL be paused rather than disposed, preserving their webview state for faster restoration.

#### Scenario: Activate site on domain occupied by background-active site

**Given** Site A (`github.com/personal`) is currently active and has `backgroundActive` set to `true`
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's cookies are captured and saved
**And** Site A's webview is paused (not disposed)
**And** Site B's webview is created with its stored cookies

#### Scenario: Return to paused background-active site

**Given** Site A was paused due to domain conflict (not disposed)
**And** Site B is currently active on the same domain
**When** the user selects Site A
**Then** Site B's cookies are captured
**And** Site A's cookies are restored
**And** Site A's webview is resumed (not recreated)
