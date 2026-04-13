# Per-Site Cookie Isolation - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: ISO-001 - Mutual Exclusion

Only ONE webview per second-level domain SHALL be active at a time. The `backgroundActive` flag does NOT exempt a site from domain conflicts — same-domain mutual exclusion still applies unconditionally because the CookieManager is a process-wide singleton that can only hold one cookie set per domain.

#### Scenario: Domain conflict with background-active site on same domain

**Given** Site A (`github.com/personal`) is loaded and has `backgroundActive` set to `true`
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's cookies are captured and saved to secure storage
**And** Site A's webview is disposed (same as non-background-active sites)
**And** the CookieManager is cleared
**And** Site B's cookies are restored and its webview is created

#### Scenario: Background-active site on different domain survives domain conflict

**Given** Site A (`slack.com`) is loaded with `backgroundActive` set to `true`
**And** Site B (`github.com/personal`) is the active site
**And** Site C (`github.com/work`) exists
**When** the user selects Site C (triggering domain conflict with Site B)
**Then** Site B is unloaded (cookies captured, webview disposed)
**And** `deleteAllCookies()` clears the CookieManager
**And** Site C's cookies are restored
**And** Site A's cookies are ALSO restored to the CookieManager
**And** Site A's webview continues running with valid cookies

### Requirement: ISO-UNLOAD-BG - Cookie Restoration for Background-Active Sites After Clear

After `_unloadSiteForDomainSwitch` calls `deleteAllCookies()`, the system SHALL restore cookies for all remaining loaded sites that have `backgroundActive` set to `true`, in addition to restoring cookies for the target site.

#### Scenario: Multiple background-active sites across domains during conflict switch

**Given** Site A (`slack.com`, backgroundActive=true) is loaded
**And** Site B (`teams.microsoft.com`, backgroundActive=true) is loaded
**And** Site C (`github.com/personal`) is loaded and active
**And** Site D (`github.com/work`) exists
**When** the user selects Site D (domain conflict with Site C)
**Then** all loaded sites' cookies are captured
**And** Site C's webview is disposed
**And** `deleteAllCookies()` clears the CookieManager
**And** Site D's cookies are restored (target site)
**And** Site A's cookies are restored (background-active, different domain)
**And** Site B's cookies are restored (background-active, different domain)
**And** Site A and Site B continue running JS with authenticated sessions

#### Scenario: Non-background-active site does not get cookies restored

**Given** Site A (`slack.com`, backgroundActive=false) is loaded but paused
**And** Site B (`github.com/personal`) is active
**And** Site C (`github.com/work`) exists
**When** the user selects Site C (domain conflict with Site B)
**Then** `deleteAllCookies()` clears the CookieManager
**And** Site C's cookies are restored
**And** Site A's cookies are NOT restored (it is paused, not running JS)
