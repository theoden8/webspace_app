# LocalCDN - Local CDN Resource Caching

**Status:** Implemented

## Purpose

Serve CDN-hosted resources (JavaScript, CSS, fonts) from a local cache to prevent CDN providers from tracking users across websites.

## Problem Statement

When visiting websites, browsers download JavaScript libraries, CSS frameworks, and fonts from Content Delivery Networks (CDNs) like cdnjs.cloudflare.com, cdn.jsdelivr.net, and ajax.googleapis.com. These CDN providers can track users across websites by correlating requests. The same library (e.g., jQuery 3.7.1) may be served from different CDN providers on different websites, giving multiple third parties visibility into a user's browsing habits.

## Solution

Intercept CDN resource requests at the webview level and serve them from a local cache. Resources are always downloaded from a single trusted source (cdnjs.cloudflare.com), never from the original CDN. This provides:

1. **Privacy** - The original CDN (googleapis, jsdelivr, unpkg, etc.) never sees the request
2. **Cross-CDN deduplication** - jQuery from googleapis, cloudflare, and jsdelivr all map to the same cached copy
3. **Pre-download** - Popular resources can be downloaded proactively via app settings (like DNS blocklist)
4. **On-demand caching** - Resources not pre-downloaded are fetched from cdnjs on first encounter
5. **Performance** - Cached resources load instantly from disk

Works on Android via `shouldInterceptRequest`. On iOS/macOS, the feature degrades gracefully (CDN requests pass through normally).

## Requirements

### LCDN-001: CDN URL Pattern Matching

The service SHALL recognize URLs from major CDN providers and extract a canonical (library, version, file) tuple.

#### Scenario: cdnjs.cloudflare.com URL

- **Given** a URL `https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js`
- **When** the URL is checked against CDN patterns
- **Then** it matches with cache key `jquery/3.7.1/jquery.min.js`

#### Scenario: cdn.jsdelivr.net npm URL

- **Given** a URL `https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.min.js`
- **When** the URL is checked against CDN patterns
- **Then** it matches with cache key `bootstrap/5.3.0/dist/js/bootstrap.min.js`

#### Scenario: Non-CDN URL

- **Given** a URL `https://example.com/script.js`
- **When** the URL is checked against CDN patterns
- **Then** it does not match any pattern (returns null)

### LCDN-002: Cross-CDN Deduplication

The same library served from different CDN providers SHALL produce the same cache key.

#### Scenario: jQuery from multiple CDNs

- **Given** jQuery 3.7.1 is requested from cdnjs.cloudflare.com, cdn.jsdelivr.net, ajax.googleapis.com, and cdn.bootcss.com
- **When** cache keys are computed for all four URLs
- **Then** all four produce the same cache key `jquery/3.7.1/jquery.min.js`

### LCDN-003: Trusted Source Download

Resources SHALL always be downloaded from cdnjs.cloudflare.com. The original CDN that was requested SHALL NOT be contacted.

#### Scenario: Resource requested from googleapis

- **Given** a page requests `https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js`
- **When** the resource is not in the local cache
- **Then** it is downloaded from `https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js`
- **And** googleapis.com never receives any request

#### Scenario: Resource already cached

- **Given** jQuery 3.7.1 was previously downloaded
- **When** any CDN URL for jQuery 3.7.1 is intercepted
- **Then** the cached copy is served without any network request

### LCDN-004: Pre-Download Popular Resources

Users SHALL be able to download a curated set of popular CDN resources via app settings, similar to DNS blocklist download.

#### Scenario: Download popular resources

- **Given** the user taps "Download" in LocalCDN app settings
- **When** the download completes
- **Then** popular resources (jQuery, Bootstrap, Font Awesome, Vue, React, etc.) are cached locally
- **And** a progress indicator shows download progress

#### Scenario: Resources already cached

- **Given** some popular resources are already cached
- **When** the user taps "Update"
- **Then** only missing resources are downloaded (cached ones are skipped)

### LCDN-005: On-Demand Caching

When a CDN URL is intercepted that isn't pre-downloaded, the system SHALL fetch the resource from cdnjs on demand.

#### Scenario: Unknown resource encountered

- **Given** a page requests a CDN resource not in the pre-download list
- **When** the URL matches a known CDN pattern
- **Then** the resource is downloaded from cdnjs, cached locally, and served
- **And** subsequent requests for the same resource are served from cache

### LCDN-006: Content Type Detection

The service SHALL return the correct MIME type for cached resources based on file extension.

#### Scenario: JavaScript file

- **Given** a cached resource with `.js` extension
- **When** the content type is determined
- **Then** `application/javascript` is returned

#### Scenario: CSS file

- **Given** a cached resource with `.css` extension
- **When** the content type is determined
- **Then** `text/css` is returned

#### Scenario: Font files

- **Given** cached resources with `.woff`, `.woff2`, or `.ttf` extensions
- **When** the content type is determined
- **Then** the appropriate font MIME type is returned

### LCDN-007: Per-Site Toggle

Each site SHALL have a `localCdnEnabled` boolean (default: `true`) that controls whether LocalCDN is applied.

#### Scenario: LocalCDN enabled (default)

- **Given** a new site is created
- **When** checking `localCdnEnabled`
- **Then** it is `true`

#### Scenario: LocalCDN disabled for a site

- **Given** a site with `localCdnEnabled` set to `false`
- **When** the webview intercepts a CDN request
- **Then** the request passes through to the CDN normally

### LCDN-008: Per-Site Settings UI

The per-site settings screen SHALL show a toggle for LocalCDN with cache statistics.

#### Scenario: Toggle display

- **Given** the user opens per-site settings
- **When** the settings list is displayed
- **Then** a "LocalCDN" toggle appears with the count of cached resources

### LCDN-009: App Settings UI

App Settings SHALL display LocalCDN with a download/update button, cache statistics, last updated timestamp, and a clear cache button.

#### Scenario: Download resources

- **Given** the user opens app settings
- **When** the user taps the download button
- **Then** popular resources are downloaded with a progress indicator

#### Scenario: Cache statistics display

- **Given** resources have been downloaded
- **When** the Privacy section is displayed
- **Then** the LocalCDN entry shows resource count, cache size, and last updated timestamp

#### Scenario: Clear cache

- **Given** the user taps the clear cache button
- **When** the cache is cleared
- **Then** all cached resources are deleted and the count resets to 0

### LCDN-010: Backward Compatibility

Existing sites without `localCdnEnabled` in their stored JSON SHALL default to `true` on deserialization.

#### Scenario: Legacy JSON without localCdnEnabled

- **Given** a site JSON without the `localCdnEnabled` field
- **When** deserialized with `WebViewModel.fromJson`
- **Then** `localCdnEnabled` defaults to `true`

### LCDN-011: Query Parameter Handling

CDN URL matching SHALL strip query parameters before pattern matching.

#### Scenario: URL with cache-busting query parameter

- **Given** a URL `https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js?v=123`
- **When** the URL is checked against CDN patterns
- **Then** it matches with cache key `jquery/3.7.1/jquery.min.js`

### LCDN-012: Cache Persistence

The cache index SHALL be persisted via SharedPreferences and the resource files SHALL be stored in the app's documents directory.

#### Scenario: App restart

- **Given** resources have been cached during a session
- **When** the app is restarted
- **Then** the cache index is loaded from SharedPreferences and cached resources are available immediately

### LCDN-013: Platform Support and Interception Scope

LocalCDN resource interception SHALL work on Android via `shouldInterceptRequest`. On iOS/macOS, the feature SHALL degrade gracefully. LocalCDN does NOT intercept `fetch()` or `XMLHttpRequest` CDN requests — in practice this is a non-issue because CDN resources are almost always loaded via static HTML tags (`<script>`, `<link>`), not JS-initiated requests.

#### Scenario: Android — static resources

- **Given** the app is running on Android
- **When** a page loads `<script src="https://cdn.jsdelivr.net/npm/jquery@3.7.1/dist/jquery.min.js">`
- **Then** `shouldInterceptRequest` intercepts the request and serves the cached copy

#### Scenario: Android — fetch/XHR CDN requests (not intercepted)

- **Given** the app is running on Android
- **When** JavaScript calls `fetch('https://cdn.jsdelivr.net/npm/some-lib@1.0/file.js')`
- **Then** the request passes through to the CDN normally (LocalCDN does not intercept fetch/XHR)

#### Scenario: iOS/macOS

- **Given** the app is running on iOS or macOS
- **When** `localCdnEnabled` is true
- **Then** the toggle is available but all CDN requests pass through normally (`shouldInterceptRequest` is Android-only)

#### Summary: What LocalCDN intercepts

| Request type | Android | iOS/macOS |
|---|---|---|
| `<script src="cdn...">` | Intercepted natively via FastSubresourceInterceptor | Not intercepted |
| `<link href="cdn...">` | Intercepted natively via FastSubresourceInterceptor | Not intercepted |
| `<img src="cdn...">` | Intercepted natively via FastSubresourceInterceptor | Not intercepted |
| CSS `@font-face url(cdn...)` | Intercepted natively via FastSubresourceInterceptor | Not intercepted |
| `fetch('cdn...')` | Not intercepted | Not intercepted |
| `XMLHttpRequest` to CDN | Not intercepted | Not intercepted |

### LCDN-014: Per-Site Replacement Counter

The service SHALL track the number of CDN requests replaced from the local cache per site, and the stats banner SHALL display this count on Android.

#### Scenario: CDN resource served from cache

- **Given** a site with `localCdnEnabled` is loaded on Android
- **When** the native `FastSubresourceInterceptor` serves a cached CDN resource for a sub-resource request
- **Then** the native side emits a `cdnEventsReady` signal and Dart's `WebInterceptNative` drains the events into `LocalCdnService.recordReplacement(siteId)`

#### Scenario: Banner shows replacement count

- **Given** at least one CDN request has been replaced for the current site on Android
- **When** the stats banner is rendered
- **Then** the banner shows `"N cdn(s) replaced"` alongside the DNS blocked/allowed counts

#### Scenario: Counter resets on app restart

- **Given** the app is terminated and relaunched
- **When** per-site replacement counts are queried
- **Then** all counts start from zero (runtime-only state)

#### Scenario: No CDN replacements

- **Given** a site where no CDN requests have been replaced
- **When** the stats banner is rendered
- **Then** no CDN count is shown

## Implementation Details

### CDN Providers Supported

| Provider | URL Pattern |
|----------|-------------|
| cdnjs (Cloudflare) | `cdnjs.cloudflare.com/ajax/libs/{lib}/{ver}/{file}` |
| jsDelivr (npm) | `cdn.jsdelivr.net/npm/{lib}@{ver}/{file}` |
| jsDelivr (GitHub) | `cdn.jsdelivr.net/gh/{user}/{lib}@{ver}/{file}` |
| unpkg | `unpkg.com/{lib}@{ver}/{file}` |
| Google CDN | `ajax.googleapis.com/ajax/libs/{lib}/{ver}/{file}` |
| jQuery CDN | `code.jquery.com/jquery-{ver}.min.js` |
| jQuery UI CDN | `code.jquery.com/ui/{ver}/{file}` |
| Bootstrap CDN (stackpath) | `stackpath.bootstrapcdn.com/bootstrap/{ver}/{file}` |
| Bootstrap CDN (maxcdn) | `maxcdn.bootstrapcdn.com/bootstrap/{ver}/{file}` |
| BootCSS (Chinese mirror) | `cdn.bootcss.com/{lib}/{ver}/{file}` |
| BootCDN (Chinese mirror) | `cdn.bootcdn.net/ajax/libs/{lib}/{ver}/{file}` |
| Staticfile (Chinese CDN) | `cdn.staticfile.org/{lib}/{ver}/{file}` |
| Baidu CDN | `libs.baidu.com/{lib}/{ver}/{file}` |
| PageCDN | `pagecdn.io/lib/{lib}/{ver}/{file}` |

### Trusted Download Source

All resources are downloaded from `https://cdnjs.cloudflare.com/ajax/libs/{lib}/{ver}/{file}`. The original CDN URL is never contacted. This means only one CDN provider (cdnjs) sees any download request, and only once per resource.

### Cache Key Format

`{library}/{version}/{file}` - lowercase library name, original version, original file path.

### Popular Resources

A curated list of ~80 popular resources is built into the service, covering:
- jQuery (8 versions)
- Bootstrap CSS + JS (8 versions)
- Popper.js (3 versions)
- Font Awesome (4 versions)
- Lodash, Moment.js, Axios, D3, Chart.js
- Vue.js, React, Angular
- Leaflet, Highlight.js, Swiper, GSAP
- Various UI libraries (Select2, Slick, Owl Carousel, SweetAlert2)

### Storage

- Cache index: `SharedPreferences` key `localcdn_cache_index` (JSON map of cache key -> file path)
- Resource files: `getApplicationDocumentsDirectory()/localcdn_cache/` directory
- Last updated timestamp: `SharedPreferences` key `localcdn_last_updated`

### Hook Ordering

LocalCDN runs inside the native `FastSubresourceInterceptor.checkUrl` on Android, AFTER DNS blocklist checking. If a CDN URL is on the DNS blocklist, DNS blocking takes priority and the request is blocked before LocalCDN can serve it. Dart-side `shouldInterceptRequest` is intentionally disabled (`useShouldInterceptRequest: false`): on modern Chromium WebView that Dart callback only fires for the main-document navigation and never for sub-resources, so all per-sub-resource logic lives in the native handler.

```kotlin
// FastSubresourceInterceptor.checkUrl (Kotlin):
// 1. DNS blocklist check + recording (runs first)
// 2. LocalCDN: if URL matches a CDN pattern and the cache key is in the
//    native cacheIndex, serve the file via WebResourceResponse(fileStream)
//    and emit a replacement event back to Dart.
```

The cache index and CDN regex patterns are pushed from Dart to the native plugin via the `web_intercept` MethodChannel (`setCdnPatterns`, `setCdnCacheIndex`) on app start and re-pushed whenever the Dart-side cache changes (download, clear). Replacement events are batched natively and drained by Dart on the `cdnEventsReady` signal, which increments `LocalCdnService._replacementsPerSite[siteId]`.

Note: the native handler only serves pre-downloaded resources; on-demand fetching from cdnjs is still handled in Dart (and only fires if the Dart callback is ever re-enabled). It is NOT called for `fetch()` or `XMLHttpRequest` CDN requests — those never reach the `ContentBlockerHandler`.

### Data Model

```dart
// WebViewModel field
bool localCdnEnabled; // default: true

// WebViewConfig field
final bool localCdnEnabled; // default: true

// InAppWebViewSettings — native interceptor runs via contentBlockerHandler
useShouldInterceptRequest: false
```

## Files

### Created
- `lib/services/localcdn_service.dart` - LocalCDN service singleton with CDN patterns, popular resource manifest, download, caching
- `test/localcdn_service_test.dart` - Unit tests for URL pattern matching, content type detection, cache state
- `openspec/specs/localcdn/spec.md` - This specification
- `fastlane/metadata/android/en-US/changelogs/13.txt` - Changelog entry

### Modified
- `lib/web_view_model.dart` - Added `localCdnEnabled` field with serialization
- `lib/services/webview.dart` - Added `localCdnEnabled` to `WebViewConfig`; disabled the Dart `shouldInterceptRequest` callback on Android in favour of the native interceptor
- `lib/services/localcdn_service.dart` - Per-site replacement counter, cdnPatternStrings / cacheIndexSnapshot getters, and cache-change listeners for the native bridge
- `lib/services/web_intercept_native.dart` - Renamed from `dns_block_native.dart`; now pushes CDN patterns + cache index to native and drains CDN replacement events
- `lib/widgets/dns_block_banner.dart` - Stats banner also shows LocalCDN replacement count on Android
- `lib/screens/settings.dart` - Per-site LocalCDN toggle
- `lib/screens/app_settings.dart` - LocalCDN download button, progress indicator, cache stats, clear cache
- `lib/main.dart` - LocalCDN service initialization + initial sync of patterns/index to native
- `android/app/src/main/kotlin/.../WebInterceptPlugin.kt` - Renamed from `DnsBlockPlugin.kt`; `FastSubresourceInterceptor` now also matches CDN URLs and serves from the shared cache directory
- `test/web_view_model_test.dart` - Tests for `localCdnEnabled` field
- `README.md` - Added LocalCDN to features list
- `CLAUDE.md` - Added LocalCDN to spec table
- `fastlane/metadata/android/en-US/full_description.txt` - Updated description

## Testing

### Unit Tests

```bash
fvm flutter test test/localcdn_service_test.dart
fvm flutter test test/web_view_model_test.dart
```

### Manual Testing

1. Open App Settings > Privacy > LocalCDN
2. Tap "Download" to pre-download popular resources
3. Verify progress indicator shows download progress
4. Verify resource count and cache size are displayed
5. Visit a website that loads jQuery or Bootstrap from a CDN (e.g., most WordPress sites)
6. Check that the resource is served locally (no request to the original CDN)
7. Visit another page using the same library from a different CDN provider
8. Verify the cached copy is served
9. Toggle LocalCDN off for a site in per-site settings
10. Verify CDN requests pass through normally
11. Clear cache in App Settings and verify count resets to 0
