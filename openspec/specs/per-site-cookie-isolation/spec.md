# Per-Site Cookie Isolation

## Status
**Implemented**

## Purpose
Implements cookie isolation between sites on the same domain. This allows users to have multiple accounts (e.g., two GitHub accounts) as separate sites without session sharing.

## Problem Statement

The `CookieManager` in `flutter_inappwebview` is a singleton that shares cookies across all webviews. When a user has multiple sites on the same domain (e.g., `github.com/personal` and `github.com/work`), they share the same session cookies, causing:

1. Automatic login to wrong account when switching sites
2. Inability to maintain separate sessions for work/personal accounts
3. Session conflicts when both sites are loaded

## Solution

Implement mutual exclusion: only ONE webview per second-level domain can be active at a time. When switching to a different site on the same domain:

1. Capture departing site's cookies from CookieManager
2. Store cookies on the departing WebViewModel (keyed by siteId)
3. Dispose departing site's webview
4. Clear CookieManager for the domain
5. Restore arriving site's stored cookies to CookieManager
6. Create arriving site's webview

## Requirements

### Requirement: ISO-001 - Mutual Exclusion

Only ONE webview per second-level domain SHALL be active at a time.

#### Scenario: Activate site on occupied domain

**Given** Site A (`github.com/personal`) is currently active
**And** Site B (`github.com/work`) exists
**When** the user selects Site B
**Then** Site A's webview is disposed
**And** Site B's webview is created

### Requirement: ISO-002 - Cookie Capture on Unload

The system SHALL capture cookies before unloading a webview due to domain conflict.

#### Scenario: Capture cookies before switch

**Given** Site A is active with session cookies
**When** Site A is unloaded due to domain conflict
**Then** Site A's current cookies are captured from CookieManager
**And** cookies are persisted to secure storage by siteId

### Requirement: ISO-003 - Cookie Restoration on Load

The system SHALL restore site-specific cookies when activating a site.

#### Scenario: Restore cookies on activation

**Given** Site B has previously stored cookies
**When** Site B is activated
**Then** Site B's cookies are loaded from secure storage
**And** cookies are set in CookieManager before webview creation

### Requirement: ISO-004 - CookieManager Cleanup

The system SHALL clear domain cookies from CookieManager between site switches on the same domain.

#### Scenario: Clean CookieManager on switch

**Given** Site A's cookies are in CookieManager
**When** switching to Site B on same domain
**Then** all cookies for the domain are deleted from CookieManager
**Before** Site B's cookies are restored

### Requirement: ISO-005 - Incognito Exemption

Incognito sites SHALL NOT trigger or be affected by domain conflicts.

#### Scenario: Incognito site coexists with regular site

**Given** Site A (regular) is active on `github.com`
**And** Site B (incognito) is on `github.com`
**When** Site B is selected
**Then** Site A remains loaded (no conflict)
**And** both sites can be active simultaneously

### Requirement: ISO-006 - Per-Site Storage

Cookies SHALL be stored per-site (by unique siteId), not per-domain.

#### Scenario: Multiple sites same domain with different cookies

**Given** Site A (`github.com/personal`) has cookies `[session=abc]`
**And** Site B (`github.com/work`) has cookies `[session=xyz]`
**When** cookies are persisted
**Then** Site A's cookies are stored under Site A's siteId
**And** Site B's cookies are stored under Site B's siteId

### Requirement: ISO-007 - Nested Webview Unchanged

Nested webviews (InAppBrowser for external links) SHALL continue using the singleton CookieManager without isolation.

#### Scenario: Open external link in nested webview

**Given** Site A is active
**When** an external link opens in InAppBrowser
**Then** the nested webview uses shared CookieManager
**And** no cookie capture/restore occurs

## Implementation Details

### Domain Comparison

Uses second-level domain (TLD + SLD) for conflict detection:
- `api.github.com` -> `github.com`
- `gist.github.com` -> `github.com`
- Sites sharing second-level domain are considered conflicting

### Site ID Generation

Each WebViewModel has a unique `siteId` field:
- Auto-generated on creation using timestamp + random
- Preserved through serialization
- Used as storage key for cookies

### Cookie Storage

Cookies stored in `CookieSecureStorage` keyed by siteId:
- Legacy domain-keyed data is migrated on first access
- Each site maintains its own isolated cookie store

## Files

### Modified
- `lib/web_view_model.dart` - Added siteId, captureCookies(), disposeWebView()
- `lib/main.dart` - Domain conflict detection, async _setCurrentIndex()
- `lib/services/webview.dart` - Added deleteAllCookiesForUrl() to CookieManager
- `lib/services/cookie_secure_storage.dart` - Added siteId-based methods

### Created
- `test/cookie_isolation_test.dart` - Unit tests for isolation logic
- `openspec/specs/per-site-cookie-isolation/spec.md` - This specification

## Migration

For existing users upgrading:
1. On first load, cookies are migrated from domain-keyed to siteId-keyed
2. First site for each domain receives the domain's cookies
3. Additional sites on same domain start fresh
4. Users can log in to each site; cookies are captured per-site going forward

## Testing

```bash
# Run cookie isolation tests
flutter test test/cookie_isolation_test.dart

# Run all tests
flutter test
```

## Manual Testing

1. Create two sites on same domain (e.g., `github.com/personal`, `github.com/work`)
2. Log into first site, verify session established
3. Switch to second site, verify first site's webview is disposed
4. Log into second site with different account
5. Switch back to first site, verify original session is restored
6. Create incognito site on same domain, verify no conflict occurs
