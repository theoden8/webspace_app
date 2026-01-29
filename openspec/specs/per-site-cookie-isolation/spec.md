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

### Requirement: ISO-008 - Per-Site URL Blocking

Each site's webview SHALL use its own `initUrl` for domain comparison when deciding whether to allow navigation or open in a nested webview.

#### Scenario: Site-specific domain comparison

**Given** Site A (`github.com`) and Site B (`gitlab.com`) are both loaded in IndexedStack
**When** Site B navigates to `gitlab.com/explore`
**Then** navigation is allowed (same normalized domain)
**And** Site A's domain (`github.com`) is NOT used for comparison

#### Scenario: Cross-domain opens nested webview

**Given** Site A (`github.com`) is active
**When** user clicks a link to `gitlab.com`
**Then** navigation is blocked
**And** `gitlab.com` opens in nested webview with `homeTitle="GitHub"`

#### Scenario: Parallel loaded sites maintain separate domain contexts

**Given** Sites A, B, C are all loaded simultaneously in IndexedStack
**When** each site navigates within its own domain
**Then** all navigations are allowed
**And** no cross-site interference occurs

### Requirement: ISO-009 - Widget Identity Preservation

Each webview widget SHALL maintain its identity via `ValueKey(siteId)` to prevent Flutter from reusing widget state incorrectly.

#### Scenario: Switching sites preserves widget identity

**Given** Site A and Site B are in IndexedStack
**When** user switches from Site A to Site B and back
**Then** each widget maintains its own state
**And** callbacks reference the correct site's `initUrl`

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

### Nested Webview URL Blocking (shouldOverrideUrlLoading)

Each site's webview has a `shouldOverrideUrlLoading` callback that:
1. Compares the request URL's normalized domain with the site's `initUrl` normalized domain
2. If same domain: allows navigation (returns `true`)
3. If different domain: blocks navigation, opens URL in nested InAppBrowser with site's name as `homeTitle`

```dart
shouldOverrideUrlLoading: (url, shouldAllow) {
  final requestNormalized = getNormalizedDomain(url);
  final initialNormalized = getNormalizedDomain(initUrl);  // Captured from closure

  if (requestNormalized == initialNormalized) {
    return true;  // Allow - same logical domain
  }

  launchUrlFunc(url, homeTitle: name);  // Open nested webview
  return false;  // Cancel navigation
}
```

**Critical**: The callback captures `initUrl` from the WebViewModel instance's closure. Each site must have its own callback instance to prevent cross-site interference.

### Widget Identity with ValueKey

IndexedStack keeps all child widgets in the tree. To ensure Flutter doesn't incorrectly reuse widget state when switching sites:

```dart
IndexedStack(
  index: currentIndex,
  children: [
    for (final model in webViewModels)
      Column(
        key: ValueKey(model.siteId),  // Ensures widget identity
        children: [model.getWebView(...)],
      ),
  ],
)
```

## Files

### Modified
- `lib/web_view_model.dart` - siteId, domain functions, captureCookies(), disposeWebView()
- `lib/main.dart` - Domain conflict detection, async _setCurrentIndex(), _unloadSiteForDomainSwitch()
- `lib/services/webview.dart` - deleteAllCookies() method on CookieManager
- `lib/services/cookie_secure_storage.dart` - loadCookiesForSite(), saveCookiesForSite(), removeOrphanedCookies()

### Created
- `test/cookie_isolation_test.dart` - Unit tests for domain extraction, aliases, siteId
- `test/cookie_isolation_integration_test.dart` - Integration tests with mock CookieManager
- `test/nested_webview_navigation_test.dart` - Tests for per-site URL blocking and widget identity
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

### Nested Webview Navigation Tests

```bash
# Run nested webview navigation tests (per-site URL blocking)
flutter test test/nested_webview_navigation_test.dart
```

Navigation tests cover:
- Each site uses its own `initUrl` for domain comparison
- Parallel loaded sites don't interfere with each other
- Rapid switching between sites maintains correct domain checks
- Domain aliases work correctly per site (gmail.com -> google.com)
- Cross-domain navigation opens nested webview with correct `homeTitle`
- Widget identity preserved via `ValueKey(siteId)` in IndexedStack

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

### Nested Webview Navigation Testing

1. Create Site A (`github.com`) and Site B (`gitlab.com`)
2. Click Site A, then click Site B
3. On Site B, click a link to `gitlab.com/explore`
4. Verify navigation stays in Site B's webview (NOT opened as nested)
5. On Site B, click a link to `github.com`
6. Verify link opens in nested webview with "GitLab" as home title
7. Switch back to Site A, click a link to `gitlab.com`
8. Verify link opens in nested webview with "GitHub" as home title

### Parallel Site Navigation Testing

1. Create 3 sites on different domains (e.g., GitHub, GitLab, Bitbucket)
2. Visit each site to ensure all 3 are loaded in IndexedStack
3. On each site, navigate within its own domain
4. Verify all navigations stay in their respective webviews
5. Verify no site uses another site's domain for URL blocking
