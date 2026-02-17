# Hagezi DNS Blocklist Domain Blocking

## Status
**Implemented**

## Purpose

Block navigation to ad, malware, and tracker domains at the webview level using curated domain blocklists from the [Hagezi](https://github.com/hagezi/dns-blocklists) project. This is orthogonal to ClearURLs (which strips query parameters) — DNS blocking prevents navigation to entire domains.

## Problem Statement

Many websites load resources from known ad-serving, malware, and tracking domains. Users who value privacy and security should be able to block navigation to these domains entirely. Hagezi maintains curated DNS blocklists at 5 severity levels (~114K–522K domains), providing a well-maintained source of blocked domains.

## Solution

A singleton `DnsBlockService` downloads domain lists from Hagezi mirrors, caches them to disk, and loads them into a `Set<String>` for O(1) lookups. A global severity level slider (0–5) in App Settings controls which list is downloaded. A per-site toggle allows disabling blocking for sites that break. The blocking hook is inserted in `shouldOverrideUrlLoading` before ClearURLs processing.

---

## Requirements

### Requirement: DNS-001 - Blocklist Download with Mirror Fallback

Users SHALL be able to download a DNS blocklist at their chosen severity level. The system SHALL try 3 mirror URLs in order on failure.

#### Scenario: Download blocklist

**Given** the user opens App Settings
**And** selects severity level "Pro" on the slider
**When** the user taps the download button
**Then** the system tries `cdn.jsdelivr.net` first
**And** on success, saves the domain list to disk
**And** parses domains into memory
**And** shows a SnackBar with domain count (e.g., "DNS blocklist updated (392,490 domains)")

#### Scenario: Primary mirror fails

**Given** the primary mirror (`cdn.jsdelivr.net`) returns a non-200 status or times out (15s)
**When** the download is attempted
**Then** the system tries `gitlab.com/hagezi/mirror` next
**And** then `codeberg.org/hagezi/mirror2` if that also fails

#### Scenario: All mirrors fail

**Given** all 3 mirrors fail
**When** the download is attempted
**Then** a failure SnackBar is shown
**And** any previously cached blocklist remains available

---

### Requirement: DNS-002 - Severity Levels

The system SHALL support 6 levels (0–5), each corresponding to a specific Hagezi domain list file.

| Level | Name | File |
|-------|------|------|
| 0 | Off | — (clears blocklist) |
| 1 | Light | `domains/light.txt` |
| 2 | Normal | `domains/multi.txt` |
| 3 | Pro | `domains/pro.txt` |
| 4 | Pro++ | `domains/pro.plus.txt` |
| 5 | Ultimate | `domains/ultimate.txt` |

#### Scenario: Set level to Off

**Given** the user sets the slider to 0 (Off)
**When** the user taps the download button
**Then** the domain set is cleared
**And** the cached file is deleted
**And** the level and timestamp are cleared from SharedPreferences
**And** a SnackBar shows "DNS blocklist disabled"

---

### Requirement: DNS-003 - Blocklist Caching

Downloaded blocklists SHALL be cached on disk and loaded at app startup without network access.

#### Scenario: Load cached blocklist on startup

**Given** a blocklist has been previously downloaded at level 3
**When** the app starts
**Then** the cached domain file is loaded from disk
**And** the domains are parsed into memory
**And** domain blocking is available immediately

#### Scenario: First launch without blocklist

**Given** no blocklist has been downloaded
**When** the app starts
**Then** no domains are loaded
**And** `isBlocked()` always returns false

---

### Requirement: DNS-004 - Domain Matching

The system SHALL block URLs whose host matches a domain in the blocklist, including subdomain matching via domain hierarchy walk-up. Partial string matches SHALL NOT occur.

#### Scenario: Exact domain match

**Given** `tracker.net` is in the blocklist
**When** the webview navigates to `https://tracker.net/path`
**Then** navigation is cancelled

#### Scenario: Subdomain blocked by parent

**Given** `tracker.net` is in the blocklist
**When** the webview navigates to `https://sub.tracker.net/path`
**Then** navigation is cancelled (parent domain `tracker.net` is blocked)

#### Scenario: No partial string match

**Given** `tracker.net` is in the blocklist
**When** the webview navigates to `https://mytracker.net/path`
**Then** navigation is allowed (`mytracker.net` is not a subdomain of `tracker.net`)

#### Scenario: Parent domain not blocked by child

**Given** `ads.example.com` is in the blocklist
**When** the webview navigates to `https://example.com/`
**Then** navigation is allowed (only `ads.example.com` and its subdomains are blocked)

---

### Requirement: DNS-005 - Per-Site Toggle

Each site SHALL have a `dnsBlockEnabled` setting (default: `true`) that controls whether DNS blocking is applied.

#### Scenario: Disable DNS blocking for a site

**Given** a site has DNS blocking disabled in its settings
**When** the site navigates to a blocked domain
**Then** navigation is allowed

#### Scenario: Default enabled

**Given** a new site is created
**Then** `dnsBlockEnabled` defaults to `true`

#### Scenario: Setting persists

**Given** a site has DNS blocking disabled
**When** the app is restarted
**Then** the setting remains disabled

#### Scenario: Toggle disabled when no blocklist

**Given** no blocklist has been downloaded
**When** the user opens site settings
**Then** the DNS Blocklist toggle is greyed out (disabled)

---

### Requirement: DNS-006 - App Settings UI

App Settings SHALL display a severity level slider and download button in the Privacy section.

#### Scenario: Slider and download UI

**Given** the user opens App Settings
**Then** a slider with 6 positions (Off through Ultimate) is shown
**And** labels for each level are displayed below the slider
**And** a download/sync button is shown to the right

#### Scenario: Slider does not auto-download

**Given** the user moves the slider from Pro to Ultimate
**Then** no download occurs automatically
**And** the download icon changes to indicate a new level is selected

#### Scenario: Spinning icon during download

**Given** the user taps the download button
**When** the download is in progress
**Then** the sync icon spins continuously
**And** the slider is disabled

#### Scenario: Slider resets on screen open

**Given** the downloaded level is Pro (3)
**When** the user opens App Settings
**Then** the slider is set to position 3 (Pro)

---

### Requirement: DNS-007 - Last Updated Display

App Settings SHALL display when the blocklist was last downloaded, along with the level name and domain count.

#### Scenario: Show blocklist info

**Given** a Pro blocklist was downloaded with 392,490 domains on 2026-02-17 at 14:30
**When** the user opens App Settings
**Then** the DNS Blocklist tile shows "Pro - 392K domains"
**And** shows "Updated: 2026-02-17 14:30:00"

#### Scenario: No blocklist downloaded

**Given** no blocklist has been downloaded
**When** the user opens App Settings
**Then** the DNS Blocklist tile shows "Not configured"

---

### Requirement: DNS-008 - Hook Ordering

The DNS block check SHALL be inserted in `shouldOverrideUrlLoading` AFTER the captcha challenge allowlist and BEFORE ClearURLs processing.

#### Scenario: Hook ordering

**Given** a URL matches a captcha challenge domain
**When** `shouldOverrideUrlLoading` is called
**Then** the URL is allowed (captcha takes priority over DNS blocking)

#### Scenario: Blocked URL skips ClearURLs

**Given** a URL is on the DNS blocklist
**When** `shouldOverrideUrlLoading` is called
**Then** navigation is cancelled immediately
**And** ClearURLs processing is not performed (no point cleaning a blocked URL)

---

### Requirement: DNS-009 - License Attribution

The Hagezi DNS blocklists SHALL be credited under GPL-3.0 in the app's license page.

#### Scenario: License visible

**Given** the user opens the Licenses page
**Then** an entry for "Hagezi DNS Blocklists (domain data)" is shown
**And** it displays the GPL-3.0 license text

---

### Requirement: DNS-010 - Performance

The system SHALL parse 522K domains (Ultimate list) in under 5 seconds and perform lookups in under 1ms per call.

#### Scenario: Parse performance

**Given** a 522K domain list
**When** `loadDomainsFromString()` is called
**Then** parsing completes in under 5 seconds

#### Scenario: Lookup performance

**Given** 522K domains are loaded
**When** `isBlocked()` is called 1000 times
**Then** average lookup time is under 1ms per call

---

### Requirement: DNS-011 - Backward Compatibility

Existing sites without `dnsBlockEnabled` in their stored JSON SHALL default to `true` on deserialization.

#### Scenario: Upgrade from older version

**Given** a user upgrades from a version without DNS blocking
**When** their sites are loaded from SharedPreferences
**Then** all sites have `dnsBlockEnabled: true`

---

## Implementation Details

### DnsBlockService Singleton

`DnsBlockService` follows the same singleton pattern as `ClearUrlService`:

```dart
static DnsBlockService? _instance;
static DnsBlockService get instance => _instance ??= DnsBlockService._();
```

Key properties:
- `hasBlocklist` — whether domains are loaded
- `level` — the currently downloaded level (0–5)
- `domainCount` — number of domains in the set
- `_blockedDomains` — `Set<String>` for O(1) lookups

### Domain File Format

One domain per line. Lines starting with `#` are comments. Empty lines are skipped.

```
# Example blocklist
tracker.net
ad.example.com
malware.evil.org
```

### Domain Hierarchy Matching

```dart
bool isBlocked(String url) {
  final host = Uri.tryParse(url)?.host;
  if (host == null || host.isEmpty) return false;

  // Exact match
  if (_blockedDomains.contains(host)) return true;

  // Walk up: sub.tracker.net → tracker.net (but NOT mytracker.net)
  final parts = host.split('.');
  for (int i = 1; i < parts.length - 1; i++) {
    if (_blockedDomains.contains(parts.sublist(i).join('.'))) return true;
  }
  return false;
}
```

### Mirror Fallback

Three mirrors are tried in order with 15-second timeouts:
1. `https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/`
2. `https://gitlab.com/hagezi/mirror/-/raw/main/dns-blocklists/`
3. `https://codeberg.org/hagezi/mirror2/raw/branch/main/dns-blocklists/`

### Hook Point in WebView

DNS blocking is inserted in `shouldOverrideUrlLoading` in `WebViewFactory.createWebView()`:

```dart
shouldOverrideUrlLoading: (controller, navigationAction) async {
  final url = navigationAction.request.url.toString();
  if (_shouldBlockUrl(url)) return CANCEL;
  if (_isCaptchaChallenge(url)) return ALLOW;
  // DNS blocklist check
  if (config.dnsBlockEnabled && DnsBlockService.instance.isBlocked(url)) {
    return CANCEL;
  }
  // ClearURLs processing
  // ... per-site navigation callback
}
```

### Storage

- Domain file: `getApplicationDocumentsDirectory()/dns_blocklist.txt`
- Level: SharedPreferences key `dns_block_level`
- Timestamp: SharedPreferences key `dns_block_last_updated`

### WebViewModel Integration

`dnsBlockEnabled` field added to `WebViewModel`:
- Constructor default: `true`
- Serialized to JSON as `'dnsBlockEnabled'`
- Deserialized with `?? true` fallback for backward compatibility
- Passed through to `WebViewConfig.dnsBlockEnabled`

---

## Files

### Created
- `lib/services/dns_block_service.dart` — Singleton service: download, cache, parse, lookup
- `test/dns_block_service_test.dart` — 12 unit tests for domain matching logic
- `test/dns_block_benchmark_test.dart` — Performance benchmark (522K domains parse + lookup)
- `openspec/specs/dns-blocklist/spec.md` — This specification

### Modified
- `lib/web_view_model.dart` — Added `dnsBlockEnabled` field, serialization, pass to WebViewConfig
- `lib/services/webview.dart` — Added `dnsBlockEnabled` to WebViewConfig, DNS block hook in shouldOverrideUrlLoading
- `lib/screens/settings.dart` — Per-site DNS Blocklist toggle (SwitchListTile)
- `lib/screens/app_settings.dart` — Privacy section with slider, download button, spinning icon, domain count
- `lib/main.dart` — DnsBlockService initialization, GPL-3.0 license registration
- `test/web_view_model_test.dart` — Tests for dnsBlockEnabled serialization and defaults
- `README.md` — Feature bullet point, Tech Stack credit
- `fastlane/metadata/android/en-US/full_description.txt` — Feature mention
- `fastlane/metadata/android/en-US/changelogs/8.txt` — Changelog entry

---

## Testing

### Unit Tests

```bash
# DNS block service tests (domain matching, hierarchy, edge cases)
fvm flutter test test/dns_block_service_test.dart

# Performance benchmark (522K domain parse + lookup)
fvm flutter test test/dns_block_benchmark_test.dart

# WebViewModel serialization tests (dnsBlockEnabled field)
fvm flutter test test/web_view_model_test.dart
```

DNS block service tests cover:
- Exact domain match blocking
- Subdomain blocking (parent domain in list blocks children)
- No partial string matches (`tracker.net` does NOT block `mytracker.net`)
- Comment lines skipped
- Empty lines skipped
- Empty input → no blocking
- Domain hierarchy walk-up
- `hasBlocklist` state
- Multiple domains loaded correctly
- Invalid URL handling
- Level names defined for 0–5

Benchmark tests cover:
- Parse 522K domains in under 5 seconds (measured ~919ms)
- Lookup under 1ms per call for 1000 lookups (measured ~11.4us/call)

### Manual Testing

1. Open App Settings, set slider to Pro (3), tap download button
2. Verify spinning icon during download, then "DNS blocklist updated (N domains)" SnackBar
3. Navigate to a known blocked domain (e.g., an ad tracker from the list)
4. Verify navigation is cancelled
5. Open site Settings, disable DNS Blocklist toggle, save
6. Navigate to the same blocked domain
7. Verify navigation is now allowed
8. Set slider to Off (0), tap download, verify "DNS blocklist disabled" SnackBar
9. Navigate to the previously blocked domain, verify it loads normally
10. Check Licenses page shows "Hagezi DNS Blocklists (domain data)" with GPL-3.0
