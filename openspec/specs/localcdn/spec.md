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

The service must recognize URLs from major CDN providers and extract a canonical (library, version, file) tuple.

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

The same library served from different CDN providers must produce the same cache key.

#### Scenario: jQuery from multiple CDNs

- **Given** jQuery 3.7.1 is requested from cdnjs.cloudflare.com, cdn.jsdelivr.net, ajax.googleapis.com, and cdn.bootcss.com
- **When** cache keys are computed for all four URLs
- **Then** all four produce the same cache key `jquery/3.7.1/jquery.min.js`

### LCDN-003: Trusted Source Download

Resources are always downloaded from cdnjs.cloudflare.com, never from the original CDN that was requested.

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

Users can download a curated set of popular CDN resources via app settings, similar to DNS blocklist download.

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

When a CDN URL is intercepted that isn't pre-downloaded, the resource is fetched from cdnjs on demand.

#### Scenario: Unknown resource encountered

- **Given** a page requests a CDN resource not in the pre-download list
- **When** the URL matches a known CDN pattern
- **Then** the resource is downloaded from cdnjs, cached locally, and served
- **And** subsequent requests for the same resource are served from cache

### LCDN-006: Content Type Detection

The service must return the correct MIME type for cached resources based on file extension.

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

Each site has a `localCdnEnabled` boolean (default: true) to enable/disable LocalCDN.

#### Scenario: LocalCDN enabled (default)

- **Given** a new site is created
- **When** checking `localCdnEnabled`
- **Then** it is `true`

#### Scenario: LocalCDN disabled for a site

- **Given** a site with `localCdnEnabled` set to `false`
- **When** the webview intercepts a CDN request
- **Then** the request passes through to the CDN normally

### LCDN-008: Per-Site Settings UI

The per-site settings screen shows a toggle for LocalCDN with cache statistics.

#### Scenario: Toggle display

- **Given** the user opens per-site settings
- **When** the settings list is displayed
- **Then** a "LocalCDN" toggle appears with the count of cached resources

### LCDN-009: App Settings UI

The app settings screen shows LocalCDN with download/update button, cache statistics, last updated timestamp, and clear cache button.

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

Sites created before LocalCDN was added must default to `localCdnEnabled: true`.

#### Scenario: Legacy JSON without localCdnEnabled

- **Given** a site JSON without the `localCdnEnabled` field
- **When** deserialized with `WebViewModel.fromJson`
- **Then** `localCdnEnabled` defaults to `true`

### LCDN-011: Query Parameter Handling

CDN URLs with query parameters must be matched correctly by stripping query strings.

#### Scenario: URL with cache-busting query parameter

- **Given** a URL `https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js?v=123`
- **When** the URL is checked against CDN patterns
- **Then** it matches with cache key `jquery/3.7.1/jquery.min.js`

### LCDN-012: Cache Persistence

The cache index is persisted via SharedPreferences and the resource files are stored in the app's documents directory.

#### Scenario: App restart

- **Given** resources have been cached during a session
- **When** the app is restarted
- **Then** the cache index is loaded from SharedPreferences and cached resources are available immediately

### LCDN-013: Platform Support

LocalCDN resource interception works on Android. On other platforms, the feature degrades gracefully.

#### Scenario: Android

- **Given** the app is running on Android
- **When** `localCdnEnabled` is true
- **Then** `useShouldInterceptRequest` is enabled and CDN requests are intercepted

#### Scenario: iOS/macOS

- **Given** the app is running on iOS or macOS
- **When** `localCdnEnabled` is true
- **Then** the toggle is available but CDN requests pass through normally (no interception)

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

The `shouldInterceptRequest` callback is independent from `shouldOverrideUrlLoading` (which handles navigation). It intercepts subresource loading (scripts, stylesheets, fonts, etc.).

### Data Model

```dart
// WebViewModel field
bool localCdnEnabled; // default: true

// WebViewConfig field
final bool localCdnEnabled; // default: true

// InAppWebViewSettings
useShouldInterceptRequest: config.localCdnEnabled && Platform.isAndroid
```

## Files

### Created
- `lib/services/localcdn_service.dart` - LocalCDN service singleton with CDN patterns, popular resource manifest, download, caching
- `test/localcdn_service_test.dart` - Unit tests for URL pattern matching, content type detection, cache state
- `openspec/specs/localcdn/spec.md` - This specification
- `fastlane/metadata/android/en-US/changelogs/13.txt` - Changelog entry

### Modified
- `lib/web_view_model.dart` - Added `localCdnEnabled` field with serialization
- `lib/services/webview.dart` - Added `localCdnEnabled` to `WebViewConfig`, `shouldInterceptRequest` callback
- `lib/screens/settings.dart` - Per-site LocalCDN toggle
- `lib/screens/app_settings.dart` - LocalCDN download button, progress indicator, cache stats, clear cache
- `lib/main.dart` - LocalCDN service initialization
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
