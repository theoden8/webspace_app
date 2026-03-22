# LocalCDN - Local CDN Resource Caching

**Status:** Implemented

## Purpose

Serve CDN-hosted resources (JavaScript, CSS, fonts) from a local cache to prevent CDN providers from tracking users across websites.

## Problem Statement

When visiting websites, browsers download JavaScript libraries, CSS frameworks, and fonts from Content Delivery Networks (CDNs) like cdnjs.cloudflare.com, cdn.jsdelivr.net, and ajax.googleapis.com. These CDN providers can track users across websites by correlating requests. The same library (e.g., jQuery 3.7.1) may be served from different CDN providers on different websites, giving multiple third parties visibility into a user's browsing habits.

## Solution

Intercept CDN resource requests at the webview level. On first encounter, download the resource and cache it locally. On subsequent requests for the same resource (even from different CDN providers), serve from the local cache. This provides:

1. **Cross-CDN deduplication** - jQuery from googleapis, cloudflare, and jsdelivr all map to the same cached copy
2. **Persistent cache** - Survives browser cache clears
3. **Privacy** - After first load, no CDN sees subsequent requests for cached resources
4. **Performance** - Cached resources load instantly from disk

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

### LCDN-003: Resource Caching

CDN resources are downloaded and cached on first encounter, then served from cache on subsequent requests.

#### Scenario: First encounter - download and cache

- **Given** a CDN URL has not been seen before
- **When** the webview requests the resource
- **Then** the resource is downloaded from the CDN, saved to disk, and served to the webview

#### Scenario: Subsequent request - serve from cache

- **Given** a CDN resource has been previously cached
- **When** the webview requests the same resource (from any CDN)
- **Then** the resource is served from the local cache without contacting any CDN

### LCDN-004: Content Type Detection

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

### LCDN-005: Per-Site Toggle

Each site has a `localCdnEnabled` boolean (default: true) to enable/disable LocalCDN.

#### Scenario: LocalCDN enabled (default)

- **Given** a new site is created
- **When** checking `localCdnEnabled`
- **Then** it is `true`

#### Scenario: LocalCDN disabled for a site

- **Given** a site with `localCdnEnabled` set to `false`
- **When** the webview intercepts a CDN request
- **Then** the request passes through to the CDN normally

### LCDN-006: Per-Site Settings UI

The per-site settings screen shows a toggle for LocalCDN with cache statistics.

#### Scenario: Toggle display

- **Given** the user opens per-site settings
- **When** the settings list is displayed
- **Then** a "LocalCDN" toggle appears with the count of cached resources

### LCDN-007: App Settings UI

The app settings screen shows LocalCDN cache statistics and a clear cache button.

#### Scenario: Cache statistics display

- **Given** the user opens app settings
- **When** the Privacy section is displayed
- **Then** the LocalCDN entry shows resource count and cache size

#### Scenario: Clear cache

- **Given** the user taps the clear cache button
- **When** the cache is cleared
- **Then** all cached resources are deleted and the count resets to 0

### LCDN-008: Backward Compatibility

Sites created before LocalCDN was added must default to `localCdnEnabled: true`.

#### Scenario: Legacy JSON without localCdnEnabled

- **Given** a site JSON without the `localCdnEnabled` field
- **When** deserialized with `WebViewModel.fromJson`
- **Then** `localCdnEnabled` defaults to `true`

### LCDN-009: Query Parameter Handling

CDN URLs with query parameters must be matched correctly by stripping query strings.

#### Scenario: URL with cache-busting query parameter

- **Given** a URL `https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js?v=123`
- **When** the URL is checked against CDN patterns
- **Then** it matches with cache key `jquery/3.7.1/jquery.min.js`

### LCDN-010: Cache Persistence

The cache index is persisted via SharedPreferences and the resource files are stored in the app's documents directory.

#### Scenario: App restart

- **Given** resources have been cached during a session
- **When** the app is restarted
- **Then** the cache index is loaded from SharedPreferences and cached resources are available immediately

### LCDN-011: Platform Support

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

### Cache Key Format

`{library}/{version}/{file}` - lowercase library name, original version, original file path.

### Storage

- Cache index: `SharedPreferences` key `localcdn_cache_index` (JSON map of cache key -> file path)
- Resource files: `getApplicationDocumentsDirectory()/localcdn_cache/` directory

### Hook Ordering in shouldInterceptRequest

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
- `lib/services/localcdn_service.dart` - LocalCDN service singleton
- `test/localcdn_service_test.dart` - Unit tests for URL pattern matching, content type detection, cache state
- `openspec/specs/localcdn/spec.md` - This specification

### Modified
- `lib/web_view_model.dart` - Added `localCdnEnabled` field with serialization
- `lib/services/webview.dart` - Added `localCdnEnabled` to `WebViewConfig`, `shouldInterceptRequest` callback
- `lib/screens/settings.dart` - Per-site LocalCDN toggle
- `lib/screens/app_settings.dart` - LocalCDN cache stats and clear button
- `lib/main.dart` - LocalCDN service initialization
- `test/web_view_model_test.dart` - Tests for `localCdnEnabled` field

## Testing

### Unit Tests

```bash
fvm flutter test test/localcdn_service_test.dart
fvm flutter test test/web_view_model_test.dart
```

### Manual Testing

1. Enable LocalCDN in per-site settings (enabled by default)
2. Visit a website that loads jQuery or Bootstrap from a CDN (e.g., most WordPress sites)
3. Check App Settings > Privacy > LocalCDN - should show cached resources
4. Visit another page using the same library from a different CDN
5. The resource should be served from cache (faster load, no CDN request)
6. Toggle LocalCDN off for a site - CDN requests should pass through normally
7. Clear cache in App Settings - resource count should reset to 0
