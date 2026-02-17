# ClearURLs Tracking Parameter Removal

## Status
**Implemented**

## Purpose

Strip tracking parameters (utm_source, fbclid, etc.) from URLs loaded in webviews using rules from the [ClearURLs](https://github.com/ClearURLs/Rules) open-source project. This improves user privacy by removing tracking identifiers that websites and advertisers use to follow users across the web.

## Problem Statement

Many URLs contain tracking parameters appended by social media, newsletters, and advertising platforms. For example:
- `https://example.com/page?utm_source=twitter&utm_medium=social&fbclid=abc123`
- `https://shop.com/item?gclid=xyz&ref=campaign`

These parameters serve no functional purpose for the user but enable cross-site tracking. Users of WebSpace who value privacy should have the option to automatically strip these parameters.

## Solution

Integrate the ClearURLs rules database, which catalogs tracking parameters by provider. Rules are downloaded on-demand, cached locally, and applied synchronously at navigation time via `shouldOverrideUrlLoading`. A per-site toggle allows users to disable cleaning for sites that break with stripped parameters.

---

## Requirements

### Requirement: CURL-001 - Rule Download

Users SHALL be able to download ClearURLs rules from App Settings.

#### Scenario: Download rules

**Given** the user opens App Settings
**When** the user taps the download button in the Privacy section
**Then** rules are fetched from `https://rules2.clearurls.xyz/data.minify.json`
**And** rules are saved to the app documents directory
**And** a success SnackBar is shown

#### Scenario: Download failure

**Given** the device has no internet connection
**When** the user taps the download button
**Then** a failure SnackBar is shown
**And** any previously cached rules remain available

---

### Requirement: CURL-002 - Rule Caching

Downloaded rules SHALL be cached on disk and loaded at app startup without network access.

#### Scenario: Load cached rules on startup

**Given** rules have been previously downloaded
**When** the app starts
**Then** rules are loaded from the cached file
**And** URL cleaning is available immediately

#### Scenario: First launch without rules

**Given** rules have never been downloaded
**When** the app starts
**Then** no rules are loaded
**And** URL cleaning is skipped (URLs pass through unchanged)

---

### Requirement: CURL-003 - Query Parameter Stripping

The system SHALL strip query parameters matching provider rules from URLs during navigation.

#### Scenario: Strip utm parameters

**Given** ClearURLs rules are loaded
**And** a provider matches `google.com` with rules `[utm_source, utm_medium, utm_campaign]`
**When** the webview navigates to `https://google.com/search?q=test&utm_source=twitter&utm_medium=social`
**Then** the URL is rewritten to `https://google.com/search?q=test`
**And** the webview loads the cleaned URL

#### Scenario: Preserve non-tracking parameters

**Given** ClearURLs rules are loaded
**When** the webview navigates to `https://google.com/search?q=flutter+tutorial`
**Then** the URL is unchanged (no tracking parameters present)

#### Scenario: Strip all query parameters

**Given** a URL contains only tracking parameters
**When** cleaning is applied
**Then** the query string is removed entirely
**And** no trailing `?` remains

---

### Requirement: CURL-004 - Raw Rules

The system SHALL apply raw regex rules to the full URL string for patterns that are not query parameters (e.g., URL fragments).

#### Scenario: Apply rawRule to URL fragment

**Given** a provider has rawRule `#tracking-[a-z]+`
**When** the webview navigates to `https://example.com/page#tracking-abc`
**Then** the fragment is stripped: `https://example.com/page`

---

### Requirement: CURL-005 - Redirections

The system SHALL extract redirect targets from tracking redirect URLs.

#### Scenario: Extract redirect target

**Given** a provider has a redirection rule matching `redirect.example.com.*[?&]url=([^&]+)`
**When** the webview navigates to `https://redirect.example.com/go?url=https%3A%2F%2Ftarget.com%2Fpage&tracking=123`
**Then** the webview loads `https://target.com/page` instead

---

### Requirement: CURL-006 - Complete Provider Blocking

The system SHALL block navigation entirely for URLs matching a provider with `completeProvider: true`.

#### Scenario: Block tracking pixel

**Given** a provider matches `tracker.com` with `completeProvider: true`
**When** the webview attempts to navigate to `https://tracker.com/pixel`
**Then** navigation is cancelled

---

### Requirement: CURL-007 - Exceptions

The system SHALL skip cleaning for URLs matching a provider's exception patterns.

#### Scenario: Exception URL passes through unchanged

**Given** a provider matches `example.com` with exception `example.com/keep`
**When** the webview navigates to `https://example.com/keep?utm_source=test`
**Then** the URL is unchanged (exception matched)

---

### Requirement: CURL-008 - Per-Site Toggle

Each site SHALL have a `clearUrlEnabled` setting (default: true) that controls whether ClearURLs cleaning is applied.

#### Scenario: Disable ClearURLs for a site

**Given** a site has ClearURLs disabled in its settings
**When** the site navigates to a URL with tracking parameters
**Then** the URL is loaded as-is (no cleaning applied)

#### Scenario: Default enabled

**Given** a new site is created
**Then** `clearUrlEnabled` defaults to `true`

#### Scenario: Setting persists

**Given** a site has ClearURLs disabled
**When** the app is restarted
**Then** the setting remains disabled

---

### Requirement: CURL-009 - Idempotent Cleaning

Cleaning SHALL be idempotent: applying `cleanUrl()` to an already-cleaned URL SHALL return the same URL, preventing redirect loops.

#### Scenario: No redirect loop

**Given** a URL has been cleaned to `https://example.com/page?q=test`
**When** `cleanUrl()` is applied again (via `shouldOverrideUrlLoading` on the redirect)
**Then** the same URL is returned
**And** no further redirect occurs

---

### Requirement: CURL-010 - Last Updated Display

App Settings SHALL display when rules were last downloaded.

#### Scenario: Show last updated timestamp

**Given** rules were downloaded on 2026-02-17 at 14:30
**When** the user opens App Settings
**Then** the ClearURLs tile shows "Updated: 2026-02-17 14:30:00"

#### Scenario: Rules never downloaded

**Given** rules have never been downloaded
**When** the user opens App Settings
**Then** the ClearURLs tile shows "Not downloaded"

---

### Requirement: CURL-011 - License Attribution

The ClearURLs rules data SHALL be credited under LGPL-3.0 in the app's license page.

#### Scenario: License visible

**Given** the user opens the Licenses page
**Then** an entry for "ClearURLs (rules data)" is shown
**And** it displays the LGPL-3.0 license text

---

### Requirement: CURL-012 - Backward Compatibility

Existing sites without `clearUrlEnabled` in their stored JSON SHALL default to `true` on deserialization.

#### Scenario: Upgrade from older version

**Given** a user upgrades from a version without ClearURLs
**When** their sites are loaded from SharedPreferences
**Then** all sites have `clearUrlEnabled: true`

---

## Implementation Details

### ClearUrlService Singleton

`ClearUrlService` follows the same singleton pattern as `HtmlCacheService`:

```dart
static ClearUrlService? _instance;
static ClearUrlService get instance => _instance ??= ClearUrlService._();
```

Key properties:
- `hasRules` — whether providers are loaded (used to skip processing when no rules available)
- `_providers` — list of parsed `ClearUrlProvider` objects

### ClearUrlProvider Data Model

```dart
class ClearUrlProvider {
  final RegExp urlPattern;       // Which URLs this provider applies to
  final bool completeProvider;   // If true, block URL entirely
  final List<RegExp> rules;      // Query param name patterns to strip
  final List<RegExp> rawRules;   // Regex applied to full URL string
  final List<RegExp> exceptions; // URLs to skip cleaning
  final List<RegExp> redirections; // Extract redirect target (capture group)
}
```

### URL Cleaning Algorithm

For each provider whose `urlPattern` matches the URL:

1. **Exceptions check** — if URL matches any exception pattern, skip this provider
2. **Complete provider** — if `completeProvider` is true, return empty string (signals block)
3. **Redirections** — if any redirection regex matches, extract capture group 1 as the target URL, URL-decode it, and return
4. **Query param stripping** — parse URL, remove query parameters whose names match any rule regex. If all params stripped, remove query string entirely
5. **Raw rules** — apply each rawRule regex as a replacement (remove matches) on the full URL string

### Hook Point in WebView

ClearURL cleaning is inserted in `shouldOverrideUrlLoading` in `WebViewFactory.createWebView()`, after the blocked URL check and captcha allowlist, but before the per-site domain navigation callback:

```dart
shouldOverrideUrlLoading: (controller, navigationAction) async {
  final url = navigationAction.request.url.toString();
  if (_shouldBlockUrl(url)) return CANCEL;
  if (_isCaptchaChallenge(url)) return ALLOW;
  // ClearURLs processing
  if (config.clearUrlEnabled && ClearUrlService.instance.hasRules) {
    final cleanedUrl = ClearUrlService.instance.cleanUrl(url);
    if (cleanedUrl.isEmpty) return CANCEL;
    if (cleanedUrl != url) {
      controller.loadUrl(urlRequest: URLRequest(url: WebUri(cleanedUrl)));
      return CANCEL;
    }
  }
  // ... per-site navigation callback
}
```

No redirect loops occur because `cleanUrl()` is idempotent — a cleaned URL produces the same output when cleaned again.

### Rules File Storage

- Cached at `getApplicationDocumentsDirectory()/clearurl_rules.json`
- Last updated timestamp stored in SharedPreferences key `clearurl_last_updated`
- Rules source: `https://rules2.clearurls.xyz/data.minify.json`

### WebViewModel Integration

`clearUrlEnabled` field added to `WebViewModel`:
- Constructor default: `true`
- Serialized to JSON as `'clearUrlEnabled'`
- Deserialized with `?? true` fallback for backward compatibility
- Passed through to `WebViewConfig.clearUrlEnabled`

---

## Files

### Created
- `lib/services/clearurl_service.dart` — Singleton service: download, cache, parse, apply rules
- `test/clearurl_service_test.dart` — 18 unit tests for URL cleaning logic
- `openspec/specs/clearurls/spec.md` — This specification

### Modified
- `lib/web_view_model.dart` — Added `clearUrlEnabled` field, serialization, pass to WebViewConfig
- `lib/services/webview.dart` — Added `clearUrlEnabled` to WebViewConfig, ClearURL hook in shouldOverrideUrlLoading
- `lib/screens/settings.dart` — Per-site ClearURLs toggle (SwitchListTile)
- `lib/screens/app_settings.dart` — Privacy section with download UI, last-updated display
- `lib/main.dart` — ClearUrlService initialization, LGPL-3.0 license registration
- `test/web_view_model_test.dart` — Tests for clearUrlEnabled serialization and defaults
- `README.md` — Feature bullet point, Tech Stack credit
- `fastlane/metadata/android/en-US/full_description.txt` — Feature mention
- `fastlane/metadata/android/en-US/changelogs/8.txt` — Changelog entry (new file)

---

## Testing

### Unit Tests

```bash
# ClearURL service tests (URL cleaning, rules parsing, edge cases)
fvm flutter test test/clearurl_service_test.dart

# WebViewModel serialization tests (clearUrlEnabled field)
fvm flutter test test/web_view_model_test.dart
```

ClearURL service tests cover:
- UTM parameter stripping (single and multiple)
- fbclid parameter stripping
- Preserving URLs with no tracking params
- Removing all query params when all are tracking
- Non-matching provider URLs pass through unchanged
- Exception URLs skip cleaning
- Complete provider blocking (returns empty string)
- Redirection extraction and URL decoding
- Raw rule regex replacement
- Empty string handling
- URL without query string
- hasRules state (empty providers, no providers key, valid providers)

### Manual Testing

1. Open App Settings, tap download button in Privacy section
2. Verify "ClearURLs rules updated" SnackBar appears
3. Navigate to a URL with tracking params (e.g., paste `https://example.com?utm_source=test&utm_medium=email` in URL bar)
4. Verify the tracking parameters are stripped from the loaded URL
5. Open site Settings, disable ClearURLs toggle, save
6. Navigate to the same URL with tracking params
7. Verify parameters are preserved
8. Check Licenses page shows "ClearURLs (rules data)" with LGPL-3.0
