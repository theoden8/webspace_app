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

### Domain Comparison for Cookie Isolation

Uses `getBaseDomain()` for conflict detection:
- `api.github.com` -> `github.com`
- `gist.github.com` -> `github.com`
- Sites sharing second-level domain are considered conflicting

**Multi-part TLD Support:**
Handles country-code second-level domains like `.co.uk`, `.com.au`:
- `www.google.co.uk` -> `google.co.uk`
- `bbc.co.uk` -> `bbc.co.uk`
- `amazon.co.jp` -> `amazon.co.jp`

Defined in `_multiPartTlds` set covering 50+ common patterns.

**IP Address Support:**
IP addresses (IPv4 and IPv6) are returned as-is since they're already unique identifiers:
- `http://192.168.1.1:8080` -> `192.168.1.1`
- `http://10.0.0.1:3000/app` -> `10.0.0.1`
- `http://[::1]:8080` -> `::1`

Two sites on the same IP address will conflict (same as domains).

### Domain Aliases for Navigation (Separate from Cookie Isolation)

Uses `getNormalizedDomain()` for nested webview URL blocking only:
- `gmail.com` -> `google.com` (alias)
- `google.co.uk` -> `google.com` (regional alias)
- `claude.ai` -> `anthropic.com` (alias)
- `chatgpt.com` -> `openai.com` (alias)

**Important:** Domain aliases affect ONLY nested webview navigation, NOT cookie isolation. Two sites on `gmail.com` and `google.com` have separate cookie stores (different second-level domains).

### Site ID Generation

Each WebViewModel has a unique `siteId` field:
- Format: `{timestamp_base36}-{random_base36}` (e.g., `lqv2x3k-abc123`)
- Auto-generated on creation using `DateTime.now().microsecondsSinceEpoch`
- Preserved through serialization (JSON)
- Used as storage key for cookies

### Cookie Storage

Cookies stored in `CookieSecureStorage` keyed by siteId:
- Legacy domain-keyed data is migrated on first access
- Each site maintains its own isolated cookie store
- Empty cookie lists remove the siteId key (cleanup)

### Aggressive Cookie Clearing

When switching between same-domain sites, ALL cookies are cleared:
- Uses `CookieManager.deleteAllCookies()` instead of URL-specific deletion
- Required because services like Google set cookies on multiple domains
- Before clearing, ALL loaded sites have their cookies captured and saved

### UI Updates on Navigation

`WebViewModel.onUrlChanged` triggers `stateSetterF()` to update:
- URL bar display
- Page title extraction
- State persistence

## Files

### Modified
- `lib/web_view_model.dart` - siteId, domain functions, captureCookies(), disposeWebView()
- `lib/main.dart` - Domain conflict detection, async _setCurrentIndex(), _unloadSiteForDomainSwitch()
- `lib/services/webview.dart` - deleteAllCookies() method on CookieManager
- `lib/services/cookie_secure_storage.dart` - loadCookiesForSite(), saveCookiesForSite(), removeOrphanedCookies()

### Created
- `test/cookie_isolation_test.dart` - Unit tests for domain extraction, aliases, siteId
- `test/cookie_isolation_integration_test.dart` - Integration tests with mock CookieManager
- `openspec/specs/per-site-cookie-isolation/spec.md` - This specification

## Migration

For existing users upgrading:
1. On first load, cookies are migrated from domain-keyed to siteId-keyed
2. First site for each domain receives the domain's cookies
3. Additional sites on same domain start fresh
4. Users can log in to each site; cookies are captured per-site going forward

## Testing

### Unit Tests

```bash
# Run cookie isolation unit tests (domain extraction, siteId, aliases)
flutter test test/cookie_isolation_test.dart

# Run cookie secure storage tests (siteId-based storage)
flutter test test/cookie_secure_storage_test.dart

# Run web view model tests (serialization with siteId)
flutter test test/web_view_model_test.dart
```

### Integration Tests

```bash
# Run cookie isolation integration tests (mock CookieManager scenarios)
flutter test test/cookie_isolation_integration_test.dart
```

Integration tests cover:
- 3 sites scenario (2 same domain, 1 different)
- Different domains don't conflict
- Subdomains of same second-level domain conflict
- Incognito sites don't participate in conflicts
- Cookie persistence across domain switches
- New site on same domain starts clean
- Third-party domain always accessible alongside same-domain conflicts

### Run All Tests

```bash
flutter test
```

## Manual Testing

1. Create two sites on same domain (e.g., `github.com/personal`, `github.com/work`)
2. Log into first site, verify session established
3. Switch to second site, verify first site's webview is disposed
4. Log into second site with different account
5. Switch back to first site, verify original session is restored
6. Create incognito site on same domain, verify no conflict occurs

### Multi-part TLD Testing

1. Create site on `google.co.uk`
2. Verify it extracts to `google.co.uk` (not `co.uk`)
3. Create second site on `mail.google.co.uk`
4. Verify they conflict (same second-level domain)

### Domain Alias Testing

1. Create site on `gmail.com`
2. Navigate to a Google sign-in page
3. Verify navigation stays in same webview (gmail.com aliased to google.com for navigation)
