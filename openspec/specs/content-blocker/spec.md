# Content Blocker with ABP Filter List Support

## Status
**Implemented**

## Purpose

Block ads, trackers, and promoted content using community-maintained filter lists in ABP (Adblock Plus) syntax. Network blocking, cosmetic filtering (CSS hides, `:style()` rules, procedural actions), and ABP-specific rule modifiers (`$domain=`, `$redirect=`, `$csp=`, `$removeparam=`) all flow through Brave's `adblock-rust` engine, wrapped via FFI in [`AdblockEngine`](../../../lib/services/adblock_engine.dart).

## Problem Statement

Websites embed ads, tracking scripts, and sponsored content that degrade the browsing experience. Community-maintained filter lists like EasyList catalog tens of thousands of rules. The `flutter_inappwebview` plugin's native `ContentBlocker` API has critical limitations:

- **Android**: No native content blocker engine. The plugin implements it in Java by running O(n) regex matches per resource request in `shouldInterceptRequest`, causing timeouts with 30K+ rules. CSS `display:none` is injected with an 800ms delay and no `MutationObserver`, missing dynamic SPA content.
- **iOS/macOS**: Uses WebKit's `WKContentRuleList`, which is performant but requires Apple-specific JSON rule format, not ABP syntax.

The app instead routes every ABP decision through `adblock-rust`, the same engine Brave Browser ships. The engine handles the full rule taxonomy natively, removes the need for an in-Dart parser, and stays microsecond-fast on filter lists in the hundreds of thousands.

## Solution

Four-layer content blocking, all driven by the same engine instance:

1. **Main-document blocking** — `ContentBlockerService.isBlocked(url, sourceUrl, requestType)` in `shouldOverrideUrlLoading` cancels navs that match the engine's blocking rules.
2. **Sub-resource blocking** — Android uses a native `FastSubresourceInterceptor` that holds a JNI handle to the same engine; iOS/macOS route through the JS interceptor's `blockCheck` handler back into the Dart engine wrapper.
3. **CSS cosmetic filtering** — `<style>` tag injection at `DOCUMENT_START` for `##selector` hides, sourced from the engine's `cosmeticResources(url)` API plus the on-demand generic-class/id scan path (`hidden_class_id_selectors`).
4. **Procedural actions** — `:has-text()`, `:upward(N)`, `:remove()`, `:remove-attr()`, `:remove-class()`, and `:style()` rules are emitted by the engine and run by the page-side procedural shim.

Filter lists are downloaded on-demand, cached to disk, and concatenated as raw ABP text feeding `AdblockEngine.load(...)`. The parsed engine is serialized to a flatbuffer blob on disk so warm starts skip the multi-megabyte reparse.

---

## Requirements

### Requirement: CB-001 - Adblock-Rust Engine as Source of Truth

The system SHALL route every adblock decision — network blocking, cosmetic selectors, procedural actions, `$redirect=`, `$csp=`, `$removeparam=` — through a single instance of Brave's `adblock-rust` engine wrapped by [`AdblockEngine`](../../../lib/services/adblock_engine.dart). The engine is built unconditionally from the concatenated text of every enabled filter list; there is no in-Dart filter parser.

#### Scenario: Engine builds from enabled filter lists

**Given** the user has one or more enabled filter lists with downloaded cache files
**When** `ContentBlockerService.initialize` (or any list mutation) runs
**Then** `_rebuildEngine` concatenates the cache files' text
**And** calls `AdblockEngine.load(rulesText, enableUboResources: ...)` to instantiate the engine
**And** stores the handle in `_rustEngine`

#### Scenario: Serialized engine cache speeds up warm starts

**Given** a previous run wrote `<docs>/content_blocker_cache/.engine.bin` and `.engine.meta`
**And** the meta's `<rulesHash>:<uboFlag>` matches the current state
**When** the next `_rebuildEngine` runs
**Then** the engine is hydrated from the blob via `AdblockEngine.loadFromSerialized`
**And** the multi-megabyte text parse is skipped
**And** the load mode logs as `deserialize`

#### Scenario: Cache invalidates on rule or uBO-resources change

**Given** the on-disk `.engine.meta` records hash X with uBO flag 1
**When** either the concatenated rule text or the uBO toggle changes (`<rulesHash>:<uboFlag>` differs)
**Then** the cache is treated as a miss
**And** the engine re-parses from rule text
**And** a fresh blob is written for the next warm start

#### Scenario: Cache miss falls back to parse

**Given** the on-disk blob is missing, corrupt, or from a different adblock-rust ABI
**When** `_rebuildEngine` tries to deserialize
**Then** `AdblockEngine.loadFromSerialized` returns null
**And** the cache files are deleted
**And** the rule text is parsed fresh
**And** a fresh blob is written

#### Scenario: Engine unavailable means decisions return "allowed"

**Given** the native library cannot be loaded on this platform/ABI
**When** any of `isBlocked`, `isHostBlocked`, `redirectFor`, `cspFor`, `rewrittenUrl`, `proceduralActionsFor`, or `getEarlyCssScript` is called
**Then** the call returns the no-op value (`false` / `null` / empty list)
**And** the system logs a warning at engine-rebuild time so the user can see the platform gap in DevTools

---

### Requirement: CB-002 - Filter List Management

Users SHALL be able to manage multiple filter lists with download, enable/disable, custom list support, and per-list persistence.

#### Scenario: Default filter lists

**Given** the user opens App Settings for the first time
**Then** 4 default lists are shown: EasyList, EasyPrivacy, Fanboy's Social Blocking List, Fanboy's Annoyance List
**And** all lists are enabled by default
**And** no lists have been downloaded yet (rule count shows 0)

#### Scenario: Download a filter list

**Given** the user taps the download button on EasyList
**When** the download completes
**Then** the list text is saved to `<docs>/content_blocker_cache/<id>.txt`
**And** the engine is rebuilt with the new list included
**And** a coarse line-count proxy is stored as `ruleCount` for the settings UI

#### Scenario: Update all lists

**Given** the user taps "Update All"
**When** all enabled lists are downloaded
**Then** each list is updated with fresh rules
**And** the engine is rebuilt after each list lands
**And** a SnackBar shows the total successful downloads

#### Scenario: Toggle a list

**Given** EasyList is enabled with rules loaded
**When** the user disables EasyList
**Then** EasyList is excluded from the next `_rebuildEngine` concatenation
**And** the list metadata persists (not deleted)

#### Scenario: Add a custom list

**Given** the user taps "Add Custom List"
**When** they enter a name and URL
**Then** the custom list is added to the lists registry
**And** it can be downloaded, enabled/disabled, and removed like default lists

#### Scenario: Remove a custom list

**Given** a custom list has been added
**When** the user removes it
**Then** the list metadata, cached text file, and its rules are removed
**And** the engine is rebuilt without it

#### Scenario: List metadata persistence

**Given** 4 lists are configured (2 enabled, 2 disabled)
**When** the app is restarted
**Then** all list metadata (name, URL, enabled state, rule count, last updated) is restored from SharedPreferences

---

### Requirement: CB-003 - Network Blocking

The system SHALL block navigation and resource requests matched by the engine, for both main-document navigations and sub-resource requests. The engine handles every ABP rule shape: bare-domain (`||domain^`), path-anchored (`||domain^/path*`), regex, `$domain=`, `$third-party`, resource-type modifiers (`$script`, `$image`, etc.), and exceptions (`@@||...`).

#### Scenario: Bare-domain rule blocks main-document nav

**Given** the engine knows `||tracker.net^`
**When** the webview navigates to `https://tracker.net/path`
**Then** `ContentBlockerService.isBlocked('https://tracker.net/path')` returns true
**And** `shouldOverrideUrlLoading` cancels the navigation

#### Scenario: Subdomain blocked by bare-domain rule

**Given** the engine knows `||tracker.net^`
**When** the webview navigates to `https://sub.tracker.net/path`
**Then** the engine matches (the rule covers the whole domain tree)
**And** the navigation is cancelled

#### Scenario: Exception rule overrides block

**Given** the engine knows `||tracker.net^` and `@@||cdn.tracker.net^`
**When** the webview navigates to `https://cdn.tracker.net/resource.js`
**Then** the engine returns "allowed"
**And** the navigation is permitted

#### Scenario: $domain= modifier

**Given** the engine knows `||tracker.com^$domain=news.com`
**When** `isBlocked('https://tracker.com/x', sourceUrl: 'https://news.com/article')` is called
**Then** the result is `true`
**When** the same URL is checked with `sourceUrl: 'https://blog.com/article'`
**Then** the result is `false`

#### Scenario: Resource-type modifier gates by request type

**Given** a rule `||example.com^$image`
**When** `isBlocked(url, requestType: 'image')` is called
**Then** the rule fires
**When** the same URL is checked with `requestType: 'document'`
**Then** the rule does NOT fire

#### Scenario: Hook ordering in shouldOverrideUrlLoading

**Given** a URL is being evaluated in `shouldOverrideUrlLoading`
**Then** the content blocker check runs after the captcha allowlist and DNS blocklist
**And** before ClearURLs processing

#### Scenario: Sub-resource blocking on Android via JNI

**Given** the engine is active on Android with `libwebspace_adblock.so` bundled
**When** a page issues a sub-resource request
**Then** `FastSubresourceInterceptor.checkUrl` first walks the DNS host-only set (fast path)
**And** for hosts the DNS check let through, calls `AdblockEngineNative.checkUrl` with URL + Referer-derived sourceUrl + `Sec-Fetch-Dest`-derived requestType
**And** the JNI layer dispatches to the same adblock-rust engine the Dart side uses
**And** `$domain=` / path-anchored / `$script` / `$image` / regex rules fire on every sub-resource

#### Scenario: Sub-resource blocking on iOS/macOS via JS bridge

**Given** the engine is active on iOS or macOS
**And** the DNS-only Bloom prefilter has been delivered to the webview's JS interceptor
**When** the page issues a `fetch('https://tracker.example.com/beacon')` call
**Then** the JS interceptor invokes the `blockCheck` handler, passing URL + `lastLoadStartUrl` as `sourceUrl`
**And** the Dart handler routes through `ContentBlockerService.isBlocked` (engine call)
**And** the result is honoured by the JS interceptor

#### Scenario: Android falls back to DNS-only when JNI library missing

**Given** the engine is active in Dart but `libwebspace_adblock.so` failed to load on this Android ABI
**Then** `AdblockEngineNative.active` is false
**And** `FastSubresourceInterceptor.checkUrl` skips the engine consult
**And** sub-resources only use the DNS host-only fast path
**And** the activation log emits a warning surfacing the gap

#### Scenario: Source attribution when DNS + ABP both match

**Given** a host appears in the DNS blocklist AND would be blocked by the engine
**When** a sub-resource request is blocked
**Then** the interceptor attributes the hit to `dns` (DNS is checked first)
**And** the ABP block counter is not incremented for that request

#### Scenario: Per-source counters preserved in stats

**Given** a page load produces 10 DNS-blocked sub-resources and 3 engine-blocked sub-resources
**Then** `DnsStats.blocked` equals 13 (merged)
**And** `DnsStats.blockedByDns` equals 10
**And** `DnsStats.blockedByAbp` equals 3
**And** the stats banner displays `13 blocked`

---

### Requirement: CB-004 - Cosmetic Filtering

The system SHALL hide page elements by injecting CSS `display: none !important` rules at `DOCUMENT_START`, sourced from the engine's domain-scoped cosmetic resources and the on-demand generic-class/id scan.

#### Scenario: Domain-scoped hides injected at DOCUMENT_START

**Given** the engine's `cosmeticResources(pageUrl)` returns `hide_selectors: [".feed-promo", "#ad-leaderboard"]`
**When** the webview starts loading the page
**Then** `getEarlyCssScript` builds a `<style>` tag with those selectors as `display: none !important`
**And** the script is injected at `DOCUMENT_START` via `initialUserScripts`
**And** matching elements are never visually rendered

#### Scenario: Page reaching $generichide skips the generic scan

**Given** the engine's `cosmeticResources(pageUrl)` reports `generichide: true`
**When** the page-side generic-class/id scanner reports its classes and ids
**Then** `genericCosmeticSelectorsFor` returns an empty list
**And** no generic hides are added on top of the domain-scoped set

#### Scenario: Exception selectors carve out hides

**Given** the engine's `cosmeticResources(pageUrl)` includes `exceptions: [".real-content"]`
**When** the bridge handler computes the merged scan exceptions
**Then** the engine's `hiddenClassIdSelectors` call receives those exceptions
**And** rules whose selector matches an exception are excluded from the returned list

#### Scenario: Procedural actions emitted by the engine

**Given** the engine's `cosmeticResources(pageUrl)` returns `procedural_actions: [<JSON for :has-text(), :upward(), :remove(), :style(), :remove-attr(), :remove-class()>]`
**When** `proceduralActionsFor` is called
**Then** the JSON strings are returned verbatim
**And** the procedural shim parses each entry and runs the action against the live DOM

#### Scenario: Late-added or class-flipped elements hide reactively

**Given** the early `<style>` tag is installed at `DOCUMENT_START`
**When** a matching element is appended to the DOM after page load, OR an existing element gains a matching class/attribute later
**Then** the CSS engine re-matches automatically and the element is hidden — no JS sweep needed

---

### Requirement: CB-005 - Generic Cosmetic Selectors via Engine

Generic `##.x` cosmetic rules (no domain prefix) SHALL be looked up on demand via the engine's `hidden_class_id_selectors` API, gated on the loaded page actually using a class or id one of the rules targets. The result is injected as `display: none !important` into a `<style>` tag the same way domain-scoped rules are.

#### Scenario: JS scanner collects classes and ids on DOMContentLoaded

**Given** the engine is active for a page
**When** the page reaches DOMContentLoaded
**Then** the scanner shim built by `buildGenericCosmeticScannerShim` walks every element
**And** collects unique `classList` tokens and non-empty `id` attributes
**And** sends them to the `genericCosmeticScan` bridge handler

#### Scenario: Bridge handler returns engine-matched selectors

**Given** the page reports classes `["ad-banner", "real-content"]` and ids `["leaderboard"]`
**When** the bridge handler calls `ContentBlockerService.genericCosmeticSelectorsFor`
**Then** the service forwards to `AdblockEngine.hiddenClassIdSelectors`
**And** the engine returns only those generic selectors that target a listed class or id

#### Scenario: Returned selectors are injected as display:none

**Given** the engine returns `[".ad-banner", "#leaderboard"]`
**When** the shim's bridge promise resolves
**Then** a `<style id="_webspace_generic_cosmetic_style">` element is appended to `<head>`
**And** its `textContent` contains `\.ad-banner { display: none !important; }` and `#leaderboard { display: none !important; }`
**And** matching elements' computed `display` is `none`

#### Scenario: Empty engine response is a no-op

**Given** the engine returns `[]` (no generic rules target the page's classes/ids)
**Then** no `<style>` tag is created
**And** the existing cosmetic shim's CSS is unaffected

#### Scenario: Bridge missing degrades silently

**Given** `window.flutter_inappwebview` is undefined (cold-load race or bridge teardown)
**Then** the scanner shim returns without throwing
**And** the page renders normally

#### Scenario: Generic shim only injected when engine is loaded

**Given** the engine library is not available on this platform
**Then** `buildGenericCosmeticScannerShim` is not added to `initialUserScripts`
**And** the bridge handler would return `[]` regardless of payload

---

### Requirement: CB-006 - Per-Site Toggle

Each site SHALL have a `contentBlockEnabled` setting (default: `true`) that controls all content blocking for that site.

#### Scenario: Disable content blocking for a site

**Given** a site has content blocking disabled in its settings
**When** the site loads
**Then** no domain blocking, CSS hiding, or text hiding is applied

#### Scenario: Default enabled

**Given** a new site is created
**Then** `contentBlockEnabled` defaults to `true`

#### Scenario: Setting persists

**Given** a site has content blocking disabled
**When** the app is restarted
**Then** the setting remains disabled

#### Scenario: Toggle disabled when no rules loaded

**Given** no filter lists have been downloaded (engine has no rules)
**When** the user opens site settings
**Then** the Content Blocker toggle is greyed out

#### Scenario: Propagates to nested webviews

**Given** a site has content blocking enabled
**When** a cross-domain link opens in a nested InAppBrowser
**Then** the nested webview also has content blocking enabled

---

### Requirement: CB-007 - License Attribution

The EasyList filter lists SHALL be credited under CC BY-SA 3.0, and `adblock-rust` plus its transitive dependencies SHALL be credited in the app's license page and README.

#### Scenario: EasyList license visible

**Given** the user opens the Licenses page
**Then** an entry for "EasyList filter lists (filter data)" is shown
**And** it displays the CC BY-SA 3.0 license text crediting "The EasyList authors"

#### Scenario: Adblock-rust deps listed

**Given** the user opens the Licenses page
**Then** the engine's `depLicenses()` output is rendered as a section
**And** every crate in the adblock-rust transitive dependency tree appears with its SPDX license

#### Scenario: README attribution

**Given** a user reads the README
**Then** EasyList is listed in the Tech Stack section with license info
**And** `adblock-rust` (Brave Software) is credited there too

---

### Requirement: CB-008 - Engine Rebuild Listener Notification

Whenever the engine is rebuilt (download, toggle, remove, add custom list, uBO toggle), the system SHALL fire registered listeners so dependent caches (DNS bloom, native interceptor) can invalidate.

#### Scenario: Rules change fires listener

**Given** a caller has subscribed via `ContentBlockerService.addRulesChangedListener`
**When** any of `downloadList`, `downloadAllLists`, `toggleList`, `removeList`, `addCustomList`, `setUseUboResources`, or `initialize` completes
**Then** `_rebuildEngine` runs and invokes the listener after the engine is updated

#### Scenario: Main wiring invalidates DNS Bloom

**Given** app startup has registered `ContentBlockerService.addRulesChangedListener` from `main.dart`
**When** the listener fires
**Then** `DnsBlockService.invalidateMergedBloom` clears the cached Bloom

#### Scenario: Native Android engine kept in sync

**Given** the engine is rebuilt with new rules
**When** `_rebuildEngine` finishes loading the Dart-side engine
**Then** `WebInterceptNative.sendAdblockEngineRules(rulesText, enableUboResources)` is called
**And** the native side spins up its own engine instance from the same text
**And** clears its per-host decision cache so stale `ALLOWED` verdicts don't shadow the new rules

---

### Requirement: CB-009 - Backward Compatibility

Existing sites without `contentBlockEnabled` in their stored JSON SHALL default to `true` on deserialization.

#### Scenario: Upgrade from older version

**Given** a user upgrades from a version without content blocking
**When** their sites are loaded from SharedPreferences
**Then** all sites have `contentBlockEnabled: true`

---

### Requirement: CB-010 - uBO Resource Pool Toggle

The system SHALL gate `adblock-rust`'s uBO web_accessible_resources/ pool behind a user-facing toggle persisted as `useUboResources` (default: `true`).

#### Scenario: Default on

**Given** the user opens App Settings for the first time
**Then** the "Serve uBO redirect stubs" toggle is on by default

#### Scenario: On → $redirect= returns stub bodies

**Given** the toggle is on
**And** a filter rule contains `$redirect=noopjs` or similar
**When** a matching request is intercepted
**Then** `ContentBlockerService.redirectFor` returns a `data:` URL with the matching stub body (noop.js, 1x1.gif, neutered tracker shim)
**And** the request is served the stub instead of being dropped

#### Scenario: Off → $redirect= rules become plain blocks

**Given** the toggle is off
**When** a matching request is intercepted
**Then** `redirectFor` returns null
**And** the interceptor falls through to the empty-body block response

#### Scenario: Toggle flips engine without app restart

**Given** the user flips the toggle
**Then** `setUseUboResources` persists the value
**And** `_clearEngineCache` deletes the serialized blob (the cached engine was built with the old uBO flag)
**And** `_rebuildEngine` runs, reinstantiating the engine with the new flag
**And** subsequent decisions reflect the new flag

#### Scenario: Toggle greyed out on unsupported platforms

**Given** the engine library cannot be loaded on this platform
**When** the user opens App Settings
**Then** the "Serve uBO redirect stubs" toggle is disabled
**And** the subtitle reads "Native adblock library not available on this platform"

---

### Requirement: CB-011 - Settings Backup Round-Trip

The `useUboResources` preference SHALL round-trip through settings export/import via the `kExportedAppPrefs` registry. The retired `useRustAdblockEngine` toggle SHALL NOT round-trip.

#### Scenario: useUboResources preserved across devices

**Given** the user has flipped the toggle off
**When** they export settings and restore on another device
**Then** the imported pref preserves the value
**And** the integrity test in `test/settings_backup_test.dart` exercises this automatically

#### Scenario: Imported useRustAdblockEngine pref is ignored

**Given** an old backup JSON contains `useRustAdblockEngine: false`
**When** the user restores it on a current build
**Then** the key is silently ignored
**And** the engine is loaded as the unconditional default
**And** no warning is required (forward-compat shape: unknown keys ignore)

---

### Requirement: CB-012 - WKContentRuleList Acceleration on Apple Platforms

iOS and macOS WebViews SHALL apply ABP rules as a compiled `WKContentRuleList` in addition to the JS-bridge interceptor. The compiled rule list is derived from the same merged enabled-lists raw text the engine itself parses, via adblock-rust's `into_content_blocking()` exporter (`AdblockEngine.filterListToAppleContentBlockingJson`), shared across all WebViews, and cached on disk by content hash in `WKContentRuleListStore` so subsequent app launches and WebView creations skip compilation. The JS-bridge interceptor remains the canonical source of per-request stats because WebKit fires no callback when a content rule matches.

#### Scenario: Payload built on engine rebuild

**Given** at least one enabled filter list has a cached file
**When** `ContentBlockerService._rebuildEngine` runs (startup, download, toggle, remove, custom-list add)
**Then** `_maybeRebuildAppleContentBlockers` is called with the merged rules text and hash the engine already computed
**And** `filterListToAppleContentBlockingJson` runs synchronously on the caller isolate (matches the engine's parse pattern; the FFI call is single-digit ms for ~30K rules)
**And** the resulting `List<inapp.ContentBlocker>` is cached on the service
**And** the source-text hash is recorded so a subsequent rebuild with identical text is a no-op

#### Scenario: WebView creation passes the cached payload

**Given** the per-site `contentBlockEnabled` is true
**And** `ContentBlockerService.appleContentBlockers` is non-null
**When** `WebViewFactory.create` builds the `inapp.InAppWebViewSettings`
**Then** `settings.contentBlockers` is set to the cached list reference (not a copy)
**And** the fork's `ContentRuleListCache.apply` hashes the JSON, looks up the identifier in `WKContentRuleListStore`, installs the cached list when present, and only compiles when the disk cache misses

#### Scenario: Per-site disable empties the rule list

**Given** the per-site `contentBlockEnabled` is false
**When** `WebViewFactory.create` builds settings for that site
**Then** `settings.contentBlockers` is an empty list
**And** the fork's helper calls `removeAllContentRuleLists()` on that WebView's user content controller
**And** no content rules fire for that site's resources

#### Scenario: Cross-launch warm cache

**Given** the user launched the app at least once with the current ruleset
**When** the app launches again with the same enabled lists
**Then** `WKContentRuleListStore.lookUpContentRuleList` for the content-hashed identifier returns the already-compiled bytecode
**And** no `compileContentRuleList` runs this launch
**And** the WebView attaches the cached rule list on creation

#### Scenario: Ruleset change invalidates old cache

**Given** the user toggles an enabled list off (or adds / removes a custom list)
**When** `_maybeRebuildAppleContentBlockers` runs again
**Then** the merged text changes, producing a new content hash and a new `WKContentRuleList` identifier
**And** the fork's helper calls `removeAllContentRuleLists()` to drop the previously-installed list on the next WebView creation
**And** the new identifier compiles once and goes into the store for future hits

#### Scenario: Concurrent WebView creates coalesce one compile

**Given** the disk cache for the current identifier is cold
**When** multiple WebViews are created in quick succession with the same `contentBlockers` payload
**Then** the fork's helper queues each waiter against the in-flight compile
**And** `WKContentRuleListStore.compileContentRuleList` runs exactly once for that identifier
**And** every waiter attaches the same `WKContentRuleList` on completion

#### Scenario: Platform-gate degrades cleanly

**Given** the platform is Linux / Android / Windows / web
**When** `WebViewFactory.create` builds settings
**Then** `_appleContentBlockersFor` returns an empty list
**And** the field is harmlessly serialised across the method channel (other platforms ignore it)

#### Scenario: Library missing degrades cleanly

**Given** the platform is iOS / macOS but `webspace_adblock` failed to load
**When** `_maybeRebuildAppleContentBlockers` runs
**Then** `filterListToAppleContentBlockingJson` returns null
**And** the service logs a warning
**And** `appleContentBlockers` remains null
**And** WebView creation passes an empty list (no rule list installed)
**And** the JS-bridge interceptor continues to handle blocking + stats

#### Scenario: Stats remain JS-bridge sourced

**Given** the engine matches a content rule on a sub-resource request
**Then** the JS-bridge interceptor's Bloom-prefiltered `blockCheck` roundtrip still records the block on `DnsBlockService` with source `abp`
**(WebKit fires no `wasMatched` callback, so the JS path stays installed as the canonical stats source even when WKContentRuleList silently blocks the request first.)**

---

## Implementation Details

### Architecture: Why Not flutter_inappwebview ContentBlocker

The `flutter_inappwebview` plugin provides a `contentBlockers` parameter on `InAppWebViewSettings` that maps to platform-specific implementations:

- **iOS/macOS (WebKit):** Rules compiled into `WKContentRuleList` bytecode. Performant but the rule format is Apple-specific JSON, not ABP.
- **Android (no native API):** The plugin runs O(n) regex per resource in `shouldInterceptRequest` and applies CSS with an 800ms `Handler.postDelayed`. Times out on 30K+ rules and misses dynamic SPA content.

Our implementation routes everything through `adblock-rust` and the page-side cosmetic shim, giving identical semantics across platforms.

### ContentBlockerService Singleton

```dart
static ContentBlockerService? _instance;
static ContentBlockerService get instance => _instance ??= ContentBlockerService._();
```

Key methods (all engine-backed):
- `isBlocked(url, sourceUrl, requestType)` — engine's `shouldBlock`
- `isHostBlocked(host)` — synthesises `https://<host>/` and asks the engine
- `redirectFor(url, ...)` — engine's `$redirect=` lookup; null when no rule fires
- `rewrittenUrl(url, ...)` — engine's `$removeparam=` lookup
- `cspFor(url, ...)` — engine's `$csp=` lookup
- `getEarlyCssScript(pageUrl)` — domain-scoped hides via `cosmeticResources(pageUrl).hide_selectors`
- `getCosmeticScript(pageUrl)` — same `<style>` tag; no JS-side text rules (engine emits procedural actions instead)
- `proceduralActionsFor(pageUrl)` — engine's `cosmeticResources(pageUrl).procedural_actions`
- `genericCosmeticSelectorsFor({pageUrl, classes, ids})` — engine's `hiddenClassIdSelectors` with merged exceptions

### Default Filter Lists

| Name | URL |
|------|-----|
| EasyList | `https://easylist.to/easylist/easylist.txt` |
| EasyPrivacy | `https://easylist.to/easylist/easyprivacy.txt` |
| Fanboy's Social | `https://easylist.to/easylist/fanboy-social.txt` |
| Fanboy's Annoyance | `https://easylist.to/easylist/fanboy-annoyance.txt` |

All licensed under GPL-3.0 / CC BY-SA 3.0 (dual-licensed, used under CC BY-SA 3.0).

### Storage

- Filter list files: `<docs>/content_blocker_cache/<id>.txt`
- Engine cache: `<docs>/content_blocker_cache/.engine.bin` + `.engine.meta` (sidecar `<rulesHash>:<uboFlag>`)
- List metadata: SharedPreferences key `content_blocker_lists` (JSON string)

### Hook Point in WebView

```dart
shouldOverrideUrlLoading: (controller, navigationAction) async {
  final url = navigationAction.request.url.toString();
  if (isCaptchaChallenge(url)) return ALLOW;
  if (config.dnsBlockEnabled && DnsBlockService.instance.isBlocked(url)) return CANCEL;
  if (config.contentBlockEnabled && ContentBlockerService.instance.isBlocked(url)) {
    return CANCEL;
  }
  // ClearURLs processing...
}
```

### Cosmetic Script Injection

Two-phase injection:

1. **DOCUMENT_START** (`initialUserScripts` + `onLoadStart`): `<style>` tag with engine-supplied domain-scoped selectors as `display: none !important`. Prevents flash of unstyled content.
2. **onLoadStop**: re-asserts the same `<style>` tag (idempotent). Selector hides are owned entirely by the CSS engine; the procedural shim runs separately for `:has-text()` / `:upward()` / `:remove()` rules emitted by the engine.

Late-added or class-flipped elements hide reactively without any JS sweep.

### WebViewModel Integration

`contentBlockEnabled` field on `WebViewModel`:
- Constructor default: `true`
- Serialized to JSON as `'contentBlockEnabled'`
- Deserialized with `?? true` fallback for backward compatibility
- Passed through to `WebViewConfig.contentBlockEnabled`
- Propagated to nested InAppBrowser via `launchUrlFunc`

---

## Files

### Created
- `lib/services/content_blocker_service.dart` — Singleton service: list management, download, cache, engine instantiation, public API surface
- `lib/services/adblock_engine.dart` — Dart FFI wrapper around `webspace_adblock`
- `rust/webspace_adblock/` — Rust crate wrapping `adblock-rust` (Brave) with cbindgen-generated C header
- `lib/services/content_blocker_shim.dart` — Pure-Dart builders for the early-CSS and cosmetic JS shims
- `lib/services/generic_cosmetic_shim.dart` — Page-side class/id scanner
- `lib/services/procedural_cosmetic_shim.dart` — Page-side runner for engine-emitted procedural actions
- `openspec/specs/content-blocker/spec.md` — This specification

### Modified
- `lib/web_view_model.dart` — Added `contentBlockEnabled` field, serialization, pass to WebViewConfig
- `lib/services/webview.dart` — Added `contentBlockEnabled` to WebViewConfig, domain block hook in `shouldOverrideUrlLoading`, cosmetic + procedural shim injection
- `lib/services/dns_block_service.dart` — `BlockSource` enum, `blockedByDns` / `blockedByAbp` counters, DNS-only `getMergedBlockBloom` (ABP lives in the engine)
- `lib/services/web_intercept_native.dart` — `sendDnsDomains`, `sendAdblockEngineRules`, `isAdblockEngineSupported`
- `android/app/src/main/kotlin/.../WebInterceptPlugin.kt` — DNS host-only fast path, JNI bridge to `adblock-rust` via `AdblockEngineNative`
- `lib/widgets/stats_banner.dart` — Shows banner when either DNS or engine has rules
- `lib/screens/settings.dart` — Per-site Content Blocker toggle
- `lib/screens/app_settings.dart` — Content Blocker list management UI, uBO resources toggle
- `lib/screens/inappbrowser.dart` — Propagate `contentBlockEnabled` to nested webview
- `lib/main.dart` — `ContentBlockerService.initialize`, change-listener wiring for DNS bloom invalidation, license registration

### Removed
- `lib/services/abp_filter_parser.dart` — Legacy Dart parser; superseded by adblock-rust
- `lib/services/abp_filter_parser_async.dart` — Background-isolate wrapper for the legacy parser
- `lib/settings/app_prefs.dart::useRustAdblockEngine` — Toggle retired; engine is now the unconditional path

---

## Testing

```bash
fvm flutter test test/content_blocker_service_test.dart  # service surface + singleton
fvm flutter test test/adblock_engine_test.dart           # FFI smoke + rule parity
npm run test:js                                          # cosmetic + procedural shim behaviour
```

### Manual Testing

1. Open App Settings, scroll to Content Blocker section
2. Tap download on EasyList, verify rule count appears
3. Tap "Update All", verify all lists download
4. Open a news site, verify ad slots are hidden before they paint
5. Open LinkedIn, verify "Promoted" posts are hidden (engine procedural `:has-text()` rules)
6. Toggle "Serve uBO redirect stubs" off, reload a tracker-heavy site, verify some tracker scripts now drop instead of returning stubs (sites may break — that's the trade-off the user opted into)
7. Open site Settings, disable Content Blocker, reload page, verify ads and promoted content reappear
8. Add a custom filter list via "Add Custom List" dialog, verify it can be downloaded, toggled, and removed
9. Check Licenses page shows "EasyList filter lists (filter data)" + adblock-rust transitive deps
10. Restart app, verify the engine deserializes from the cached blob (log line `Engine active: ... (deserialize ...)`)
