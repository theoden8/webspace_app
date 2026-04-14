# Per-Site Cookie Isolation - Delta for Web Push Notifications

## MODIFIED Requirements

### Requirement: ISO-001 - Mutual Exclusion

Only ONE webview per second-level domain SHALL be active in the widget tree at a time. For background-active sites, the widget is removed from IndexedStack on domain conflict but the native WebView is preserved via `InAppWebViewKeepAlive` — JS execution, WebSocket connections, and DOM state survive. For non-background-active sites, existing dispose behavior is unchanged.

#### Scenario: Domain conflict disposes non-background-active site (unchanged)

**Given** Site A (`github.com/personal`) is loaded with `backgroundActive` set to `false`
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's cookies are captured and saved
**And** Site A's webview widget and controller are disposed (existing behavior)
**And** Site A's native WebView is destroyed
**And** Site B's webview is created with its stored cookies

#### Scenario: Domain conflict detaches background-active site via keepAlive

**Given** Site A (`github.com/personal`) is loaded with `backgroundActive` set to `true`
**And** Site A's webview was created with an `InAppWebViewKeepAlive` token
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's cookies are captured and saved to secure storage
**And** Site A's widget is removed from the IndexedStack
**And** Site A's `InAppWebViewKeepAlive` token is NOT disposed (native WebView preserved)
**And** Site A's JS timers and WebSocket connections continue running
**And** Site B's cookies are restored and its webview is created

#### Scenario: Return to keepAlive'd background-active site

**Given** Site A was detached from the widget tree via keepAlive (domain conflict)
**And** Site B is currently active on the same domain
**When** the user selects Site A
**Then** Site B's cookies are captured
**And** the CookieManager is cleared
**And** Site A's cookies are restored from secure storage
**And** Site A's widget is re-attached to IndexedStack using the same keepAlive token
**And** the same native WebView renders without page reload
**And** scroll position, DOM state, and form data are preserved

### Requirement: ISO-UNLOAD-BG - Cookie Restoration for Background-Active Sites After Clear

After `_unloadSiteForDomainSwitch` calls `deleteAllCookies()`, the system SHALL restore cookies for all remaining background-active sites (whether in IndexedStack or preserved via keepAlive), in addition to restoring cookies for the target site. This ensures their running JavaScript retains authenticated sessions.

#### Scenario: Background-active sites on other domains get cookies restored after clear

**Given** Site A (`slack.com`, backgroundActive=true) is loaded in IndexedStack
**And** Site B (`teams.microsoft.com`, backgroundActive=true) is loaded in IndexedStack
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

#### Scenario: KeepAlive'd background-active site gets cookies restored after clear

**Given** Site A (`slack.com`, backgroundActive=true) was detached via keepAlive (earlier domain conflict)
**And** Site A's native WebView is still running JS via keepAlive
**And** Site B (`github.com/personal`) is active
**And** Site C (`github.com/work`) exists
**When** the user selects Site C (domain conflict with Site B)
**Then** `deleteAllCookies()` clears the CookieManager
**And** Site C's cookies are restored
**And** Site A's cookies are ALSO restored (keepAlive'd, background-active)
**And** Site A's running JS retains authenticated access

#### Scenario: Non-background-active site does not get cookies restored

**Given** Site A (`slack.com`, backgroundActive=false) is loaded but paused
**And** Site B (`github.com/personal`) is active
**And** Site C (`github.com/work`) exists
**When** the user selects Site C (domain conflict with Site B)
**Then** `deleteAllCookies()` clears the CookieManager
**And** Site C's cookies are restored
**And** Site A's cookies are NOT restored (it is paused, not running JS)
