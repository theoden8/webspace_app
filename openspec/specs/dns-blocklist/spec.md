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

### Requirement: DNS-008 - Request Interception Hooks

The system SHALL use multiple interception hooks to block and record DNS requests across different request types and platforms.

#### Blocking: Native FastDnsBlockerHandler (Android)

On Android, sub-resource blocking runs entirely in Java via a custom `FastDnsBlockerHandler` that subclasses `ContentBlockerHandler`. The handler is injected into each `InAppWebView` by replacing the `contentBlockerHandler` public field. It uses an O(1) `HashSet<String>` lookup with domain hierarchy walk-up — no Dart roundtrip, no regex matching.

The blocked domains are sent to Java once at startup via MethodChannel. Each handler is created with a `siteId` so blocked requests are attributed to the correct site.

**Important constraint:** flutter_inappwebview's `shouldInterceptRequest` Dart callback uses a synchronous blocking platform channel. If `useShouldInterceptRequest` is true, the Dart roundtrip runs first and returns early, **skipping** `contentBlockerHandler` entirely. Therefore `useShouldInterceptRequest` MUST be false (or only enabled when LocalCDN has cached resources).

**Catches:** All sub-resource requests (`<script>`, `<img>`, `<link>`, CSS, fonts, fetch, XHR)
**Does NOT catch:** Navigations (handled by shouldOverrideUrlLoading), iOS/macOS requests

#### Blocking: shouldOverrideUrlLoading (all platforms)

Fires for navigation-level requests (link clicks, page loads, redirects). Inserted AFTER the captcha challenge allowlist and BEFORE ClearURLs processing. Records all navigations (allowed + blocked). Blocks navigations to blocklisted domains.

**Catches:** Link clicks, typed URLs, redirects, `window.location` changes
**Does NOT catch:** Sub-resources

#### Recording: PerformanceObserver JS injection (all platforms)

Injected at `DOCUMENT_START` with `buffered: true`, observes the Resource Timing API to record all loaded resources. Reports URLs back to Dart via `addJavaScriptHandler`. Cannot block — recording only. Deduplicates via a `seen` map in JS.

**Catches:** All completed resources including blocked ones (browser creates a performance entry even for 403 responses)
**Does NOT catch:** WebSocket connections, resources inside cross-origin iframes

#### Recording: onLoadStart (all platforms)

Records the page URL when a navigation starts. Ensures the banner shows immediately even for cached HTML loads that bypass shouldOverrideUrlLoading.

#### Blocking: iOS JS Interceptor

iOS/macOS cannot intercept sub-resources natively. WKWebView runs its network
stack in a separate process and exposes no equivalent to Android's
`shouldInterceptRequest`. The only native option is `WKContentRuleList`, but it
has a ~150K rule limit and compilation takes tens of seconds, while even the
smallest Hagezi blocklist ("Light") is 146K domains.

Instead, iOS uses a JavaScript interceptor injected at `DOCUMENT_START`:

- Overrides `window.fetch` — async check via `dnsCheck` handler, reject if blocked
- Overrides `XMLHttpRequest.prototype.open`/`send` — abort if blocked
- Patches `src`/`href` setters on `HTMLImageElement`, `HTMLScriptElement`,
  `HTMLLinkElement`, `HTMLIFrameElement` — defers the assignment pending the check
- `MutationObserver` on `document.documentElement` — catches statically-parsed
  elements (e.g., `<img src="tracker.com">` in initial HTML), clears the src
  attribute and removes the element if blocked

Each URL check is a `callHandler('dnsCheck', url)` roundtrip to Dart, which does
O(1) HashSet lookup in `DnsBlockService.isBlocked()`. Dart also records the
request for stats.

**Catches:** `fetch()`, `XMLHttpRequest`, dynamically created resource elements,
property-set src/href, elements inserted into DOM after script runs.

**Does NOT catch:** Resources loaded before the interceptor runs (rare at
DOCUMENT_START), static elements whose load completes before MutationObserver
fires (the initial request may go out but response is discarded when src is
cleared — some privacy leak), WebSocket, cross-origin iframe contents,
`navigator.sendBeacon()` (can be added).

#### Summary: Platform coverage

| Request type | Android block | Android record | iOS/macOS block | iOS/macOS record |
|---|---|---|---|---|
| Navigation (links, redirects) | shouldOverrideUrlLoading | shouldOverrideUrlLoading + onLoadStart | shouldOverrideUrlLoading | shouldOverrideUrlLoading + onLoadStart |
| Static sub-resources (`<script>`, `<img>`, `<link>`) | FastDnsBlockerHandler (Java) | PerformanceObserver | JS interceptor (MutationObserver + src setter) | JS interceptor + PerformanceObserver |
| `fetch()` API | FastDnsBlockerHandler (Java) | PerformanceObserver | JS interceptor (fetch override) | JS interceptor + PerformanceObserver |
| `XMLHttpRequest` | FastDnsBlockerHandler (Java) | PerformanceObserver | JS interceptor (XHR override) | JS interceptor + PerformanceObserver |
| `navigator.sendBeacon()` | FastDnsBlockerHandler (Java) | PerformanceObserver | No | PerformanceObserver |
| WebSocket | No | No | No | No |
| Cross-origin iframe resources | No | No | No | No |

#### Scenario: Hook ordering in shouldOverrideUrlLoading

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

### Requirement: DNS-012 - Per-Site DNS Statistics

The system SHALL track allowed and blocked DNS request counts per site at runtime, with a log of recent queries. Recording happens regardless of whether the per-site DNS blocking toggle is on or off — stats always record when a blocklist is loaded.

#### Scenario: Record DNS requests

**Given** a DNS blocklist is loaded
**When** the webview loads resources (navigations, scripts, images, fetch/XHR)
**Then** each request is recorded as allowed or blocked in per-site stats via multiple hooks (see DNS-008)
**And** the domain, timestamp, and block status are stored in a log (capped at 500 entries)

#### Scenario: Stats recorded even when blocking is off

**Given** a DNS blocklist is loaded
**And** DNS blocking is disabled for a site
**When** the webview loads resources
**Then** requests are still recorded (with blocked=true for domains on the list, even though they were not actually blocked)

#### Scenario: Duplicate recording

**Given** the same URL is intercepted by multiple hooks (e.g., PerformanceObserver and shouldInterceptFetchRequest)
**Then** duplicate entries may appear in the log — this is expected and reflects the actual request pipeline

#### Scenario: Stats not persisted

**Given** DNS stats have been recorded for a site
**When** the app is restarted
**Then** the stats are reset (runtime-only, not persisted to storage)

#### Scenario: Clear stats

**Given** DNS stats have been recorded for a site
**When** the user taps "Clear" in the DNS tab of Developer Tools
**Then** all stats and log entries for that site are reset to zero

---

### Requirement: DNS-013 - Live DNS Activity Banner

A collapsible banner SHALL appear at the top of the webview showing live DNS activity for the active site. The banner uses subtle grey styling (not alarming red) and can be toggled off in App Settings.

#### Scenario: Banner visible when queries recorded

**Given** a DNS blocklist is loaded
**And** at least one DNS query has been recorded for the site
**When** the user views the site
**Then** a compact grey banner at the top shows blocked and allowed counts

#### Scenario: Banner hidden when no queries

**Given** no DNS queries have been recorded for the site
**When** the user views the site
**Then** no banner is shown

#### Scenario: Expand banner

**Given** the DNS banner is visible
**When** the user taps it
**Then** it expands to show the 5 most recently blocked domains (unique, monospace)

#### Scenario: Toggle banner off in App Settings

**Given** the user opens App Settings
**When** the user disables the "DNS Block Banner" toggle
**Then** the banner is hidden for all sites
**And** the setting persists across app restarts

#### Scenario: Banner hidden when no blocklist

**Given** no DNS blocklist has been downloaded
**When** the user views any site
**Then** no banner is shown

---

### Requirement: DNS-014 - DNS Query Log in Developer Tools

Developer Tools SHALL include a DNS tab with a Pi-hole-style query log showing all recorded DNS requests.

#### Scenario: DNS tab in Developer Tools

**Given** a DNS blocklist is configured
**And** the user opens Developer Tools for a site
**Then** a "DNS" tab with a shield icon is shown

#### Scenario: Stats cards

**Given** DNS requests have been recorded for a site
**When** the user views the DNS tab
**Then** four stat cards are shown: Total, Allowed, Blocked, Block %

#### Scenario: Filter by status

**Given** the DNS query log contains both allowed and blocked entries
**When** the user selects the "Blocked" filter chip
**Then** only blocked entries are shown
**And** the "Blocked" chip shows the count

#### Scenario: Search queries

**Given** the DNS query log contains entries
**When** the user types a domain in the search field
**Then** only entries matching the search are shown

#### Scenario: Copy log

**Given** DNS entries are recorded
**When** the user taps "Copy"
**Then** the full log is copied to the clipboard in `[timestamp] BLOCKED/ALLOWED domain` format

---

### Requirement: DNS-015 - DNS Stats in Site Settings

The per-site settings screen SHALL display a compact DNS stats summary below the DNS Blocklist toggle.

#### Scenario: Stats visible

**Given** DNS blocking is active
**And** DNS requests have been recorded for the current site
**When** the user opens site settings
**Then** a row of stat chips shows total, allowed, blocked counts, and block rate percentage

#### Scenario: Stats hidden when no requests

**Given** no DNS requests have been recorded for the current site
**When** the user opens site settings
**Then** no stats row is shown

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

### Per-Site DNS Statistics

`DnsBlockService` tracks per-site statistics via `DnsStats` objects keyed by `siteId`:

```dart
class DnsStats {
  int allowed = 0;
  int blocked = 0;
  final List<DnsLogEntry> log = [];  // Capped at 500 entries
  int get total => allowed + blocked;
  double get blockRate => total > 0 ? blocked / total * 100 : 0;
}
```

A listener pattern (`addDnsLogListener`/`removeDnsLogListener`) notifies UI widgets of new log entries for live updates.

### Native Android Sub-Resource Blocking

flutter_inappwebview's `shouldInterceptRequest` Dart callback uses a synchronous
blocking platform channel that serializes concurrent sub-resource loads — only ~1
request gets through to Dart. This makes Dart-side sub-resource blocking impossible.

The solution is `FastDnsBlockerHandler` (`DnsBlockPlugin.kt`), a Kotlin class that
subclasses `ContentBlockerHandler` and runs entirely in Java:

```kotlin
class FastDnsBlockerHandler(
    private val blockedDomains: HashSet<String>,
    private val onBlocked: (String) -> Unit
) : ContentBlockerHandler() {
    init {
        // Dummy rule so Java guard `ruleList.size() > 0` passes
        ruleList.add(ContentBlocker(trigger, action))
    }
    override fun checkUrl(webView, request): WebResourceResponse? {
        val host = URI(request.url).host
        if (isBlockedDomain(host)) {  // O(1) HashSet + hierarchy walk-up
            onBlocked(host)
            return WebResourceResponse("text/plain", "utf-8", null)
        }
        return null
    }
}
```

The `DnsBlockPlugin` manages the lifecycle:
1. `setBlockedDomains` — receives domain list from Dart, stores in Java `HashSet`
2. `attachToWebViews(siteId)` — traverses view hierarchy, finds `InAppWebView`
   instances, replaces `contentBlockerHandler` field with `FastDnsBlockerHandler`
3. `onDnsBlocked(siteId, host)` — reports blocked domains back to Dart via
   MethodChannel for DNS stats (each handler has its own siteId)

**Critical constraint:** `useShouldInterceptRequest` must be `false` (or only
enabled for LocalCDN). When true, the Dart callback runs and returns early,
skipping `contentBlockerHandler.checkUrl()` entirely.

### Recording Hooks

**shouldOverrideUrlLoading** (all platforms) — navigation blocking + recording:
```dart
if (DnsBlockService.instance.hasBlocklist) {
  DnsBlockService.instance.recordRequest(siteId, url, blocked);
  if (blocked && config.dnsBlockEnabled) return CANCEL;
}
```

**onLoadStart** (all platforms) — records page URL for immediate banner display.

**PerformanceObserver JS** (all platforms) — injected at `DOCUMENT_START` with
`buffered: true`, records all completed resources via Resource Timing API.
Reports back to Dart via `addJavaScriptHandler('dnsResourceLoaded')`.

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
- `lib/services/dns_block_service.dart` — Singleton service: download, cache, parse, lookup, per-site stats
- `lib/services/dns_block_native.dart` — Dart-side interface for native Android DNS blocker
- `lib/widgets/dns_block_banner.dart` — Live DNS activity banner widget for webview overlay
- `android/app/src/main/kotlin/.../DnsBlockPlugin.kt` — Native Android plugin: FastDnsBlockerHandler (Java HashSet), DnsBlockPlugin (MethodChannel + view traversal)
- `test/dns_block_service_test.dart` — 12 unit tests for domain matching logic
- `test/dns_block_benchmark_test.dart` — Performance benchmark (522K domains parse + lookup)
- `openspec/specs/dns-blocklist/spec.md` — This specification

### Modified
- `lib/web_view_model.dart` — Added `dnsBlockEnabled` field, serialization, pass to WebViewConfig with `siteId`
- `lib/services/webview.dart` — WebViewConfig with siteId, PerformanceObserver injection, native handler attach
- `lib/screens/settings.dart` — Per-site DNS Blocklist toggle with stats summary chips
- `lib/screens/dev_tools.dart` — DNS tab with query log, stats cards, filters, copy/clear actions
- `lib/screens/app_settings.dart` — Privacy section with slider, download, DNS Block Banner toggle, native domain sync
- `lib/main.dart` — DnsBlockService + DnsBlockNative initialization, DnsBlockBanner in webview stack
- `android/app/src/main/kotlin/.../MainActivity.kt` — DnsBlockPlugin registration
- `test/web_view_model_test.dart` — Tests for dnsBlockEnabled serialization and defaults

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

#### DNS Transparency Testing

11. With DNS blocking enabled, browse a website that loads third-party trackers
12. Verify the DNS banner appears at the top showing blocked and allowed counts
13. Tap the banner to expand it, verify recently blocked domains are shown
14. Open Developer Tools, switch to the DNS tab
15. Verify stats cards show Total, Allowed, Blocked, Block % with correct values
16. Use filter chips to show only blocked or only allowed entries
17. Search for a specific domain in the query log
18. Tap "Copy" and verify the log is copied to clipboard
19. Tap "Clear" and verify stats and log are reset
20. Open site Settings, verify DNS stats row appears below the DNS toggle
21. Disable DNS blocking for the site, verify the banner disappears
