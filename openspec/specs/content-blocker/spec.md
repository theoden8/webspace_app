# Content Blocker with ABP Filter List Support

## Status
**Implemented**

## Purpose

Block ads, trackers, and promoted content using community-maintained filter lists in ABP (Adblock Plus) syntax. This includes domain-level blocking, CSS element hiding, and text-based hiding for dynamically labeled content (e.g., LinkedIn "Promoted" posts).

## Problem Statement

Websites embed ads, tracking scripts, and sponsored content that degrade the browsing experience. Community-maintained filter lists like EasyList catalog tens of thousands of rules for blocking these elements. The `flutter_inappwebview` plugin provides a native `ContentBlocker` API, but it has critical limitations:

- **Android**: No native content blocker engine. The plugin implements it in Java by running O(n) regex matches per resource request in `shouldInterceptRequest`, causing timeouts with 30K+ rules. CSS `display:none` is injected with an 800ms delay and no `MutationObserver`, missing dynamic SPA content.
- **iOS/macOS**: Uses WebKit's `WKContentRuleList` which is performant but requires Apple-specific JSON rule format, not ABP syntax.

A custom implementation is needed that parses ABP filter syntax directly and applies rules efficiently across all platforms.

## Solution

Four-layer content blocking:

1. **Main-document domain blocking** — O(1) hash set lookup in `shouldOverrideUrlLoading` for `||domain^` rules
2. **Sub-resource domain blocking** — ABP's `||domain^` set is pushed into the shared sub-resource interceptor alongside the DNS blocklist. Android uses the native `FastSubresourceInterceptor`; iOS/macOS use a JS interceptor backed by a Bloom-filter prefilter. Hits are attributed per source so per-site stats can show a merged "blocked" count while keeping DNS vs ABP separable.
3. **CSS cosmetic filtering** — `<style>` tag injection via `UserScript` at `DOCUMENT_START` for `##selector` rules, with `MutationObserver` for dynamic content
4. **Text-based hiding** — JavaScript DOM walking for `#?#` rules with `:-abp-contains()` patterns (e.g., hiding posts containing "Promoted" or "Sponsored")

Filter lists are downloaded on-demand, cached to disk, and parsed in a background isolate.

---

## Requirements

### Requirement: CB-001 - ABP Filter List Parsing

The system SHALL parse filter lists in ABP/EasyList syntax, extracting three types of rules.

#### Scenario: Parse domain block rules

**Given** a filter list containing `||tracker.example.com^`
**When** the list is parsed
**Then** `tracker.example.com` is added to the blocked domains set

#### Scenario: Parse cosmetic filter rules

**Given** a filter list containing `##.ad-banner`
**When** the list is parsed
**Then** `.ad-banner` is added as a global cosmetic selector

#### Scenario: Parse domain-specific cosmetic rules

**Given** a filter list containing `example.com##.sidebar-ad`
**When** the list is parsed
**Then** `.sidebar-ad` is added as a cosmetic selector scoped to `example.com`

#### Scenario: Parse text hide rules

**Given** a filter list containing `linkedin.com#?#div.feed-shared-update-v2:-abp-contains(Promoted)`
**When** the list is parsed
**Then** a text hide rule is created with selector `div.feed-shared-update-v2` and pattern `Promoted` scoped to `linkedin.com`

#### Scenario: Parse :-abp-contains with regex-style patterns

**Given** a filter list containing `example.com#?#div.post:-abp-contains(/Promoted|Sponsored/)`
**When** the list is parsed
**Then** a text hide rule is created with patterns `Promoted` and `Sponsored`

#### Scenario: Allow standard CSS :has() selectors

**Given** a filter list containing `##div:has(.ad-label)`
**When** the list is parsed
**Then** `div:has(.ad-label)` is added as a cosmetic selector (`:has()` is standard CSS)

#### Scenario: Parse exception rules

**Given** a filter list containing `@@||cdn.example.com^`
**When** the list is parsed
**Then** `cdn.example.com` is added to the exception domains set

#### Scenario: Skip complex exception rules

**Given** a filter list containing `@@||example.com/path$script`
**When** the list is parsed
**Then** the rule is skipped (only simple domain-anchored exceptions are supported)

#### Scenario: Convert :has-text() in cosmetic rules to text hide rules

**Given** a filter list containing `##.container:has-text(Sponsored)`
**When** the list is parsed
**Then** a text hide rule is created with selector `.container` and pattern `Sponsored`

#### Scenario: Convert :contains() in cosmetic rules to text hide rules

**Given** a filter list containing `example.com##div.post:contains(Advertisement)`
**When** the list is parsed
**Then** a text hide rule is created with selector `div.post` and pattern `Advertisement` scoped to `example.com`

#### Scenario: Rewrite :-abp-has() to standard CSS :has()

**Given** a filter list containing `##div:-abp-has(.ad-label)`
**When** the list is parsed
**Then** `div:has(.ad-label)` is added as a cosmetic selector (rewritten to standard CSS)

#### Scenario: Parse path-anchored network rules

**Given** a filter list containing `||example.com/ads/`, `||example.com^/track`, or `||example.com^*pixel.gif`
**When** the list is parsed
**Then** each rule is added to `blockedDomainPaths['example.com']` with its raw glob preserved
**And** `example.com` is NOT promoted to the whole-domain `blockedDomains` set

#### Scenario: Path-anchored rules survive option strip

**Given** a filter list containing `||ads.example.com/path$script,third-party`
**When** the list is parsed
**Then** the options are stripped (we don't classify resource types) and the residual `||ads.example.com/path` is converted to a path-anchored rule

#### Scenario: Parse uBO `:style()` cosmetic extension

**Given** a filter list containing `##.banner:style(height: 1px !important)`
**When** the list is parsed
**Then** a `StyleRule` is created with selector `.banner` and declarations `height: 1px !important`
**And** `.banner` does NOT also appear in the `display:none` cosmetic-selector set

#### Scenario: Parse domain-scoped `:style()` rule

**Given** a filter list containing `linkedin.com##.promo:style(opacity: 0.1)`
**When** the list is parsed
**Then** the `StyleRule` is scoped to `linkedin.com`

#### Scenario: Skip empty `:style()` declarations

**Given** a filter list containing `##.banner:style()` or `##:style(color:red)`
**When** the list is parsed
**Then** the rule is skipped (empty declarations or missing selector)

#### Scenario: Skip unsupported rule types

**Given** a filter list containing rules with `#$#` (snippets), `##^` (HTML filters), `$redirect`, `$csp`, `$removeparam`, or regex patterns
**When** the list is parsed
**Then** these rules are silently skipped

#### Scenario: Skip unsupported extended CSS pseudo-classes

**Given** a filter list containing selectors with `:matches-path()`, `:matches-attr()`, `:min-text-length()`, or `:watch-attr()`
**When** the list is parsed
**Then** these selectors are skipped (not supported)

#### Scenario: Case-insensitive domain matching

**Given** a filter list containing `||TRACKER.COM^`
**When** the list is parsed
**Then** `tracker.com` is added to blocked domains (lowercased)

#### Scenario: Isolate-based parsing

**Given** a large filter list (30K+ lines)
**When** the list is parsed
**Then** parsing runs in a background isolate via `compute()` to avoid blocking the UI thread

---

### Requirement: CB-002 - Filter List Management

Users SHALL be able to manage multiple filter lists with download, enable/disable, and custom list support.

#### Scenario: Default filter lists

**Given** the user opens App Settings for the first time
**Then** 4 default lists are shown: EasyList, EasyPrivacy, Fanboy's Social Blocking List, Fanboy's Annoyance List
**And** all lists are enabled by default
**And** no lists have been downloaded yet (rule count shows 0)

#### Scenario: Download a filter list

**Given** the user taps the download button on EasyList
**When** the download completes
**Then** the list is saved to disk
**And** parsed into memory (blocked domains + cosmetic selectors + text hide rules)
**And** the rule count is displayed on the list tile

#### Scenario: Update all lists

**Given** the user taps "Update All"
**When** all enabled lists are downloaded
**Then** each list is updated with fresh rules
**And** a SnackBar shows the total rule count

#### Scenario: Toggle a list

**Given** EasyList is enabled with rules loaded
**When** the user disables EasyList
**Then** EasyList rules are excluded from the aggregated rule set
**And** the list metadata persists (not deleted)

#### Scenario: Add a custom list

**Given** the user taps "Add Custom List"
**When** they enter a name and URL
**Then** the custom list is added to the list
**And** it can be downloaded, enabled/disabled, and removed like default lists

#### Scenario: Remove a custom list

**Given** a custom list has been added
**When** the user removes it
**Then** the list and its cached file are deleted
**And** its rules are removed from the aggregated set

#### Scenario: List metadata persistence

**Given** 4 lists are configured (2 enabled, 2 disabled)
**When** the app is restarted
**Then** all list metadata (name, URL, enabled state, rule count, last updated) is restored from SharedPreferences

---

### Requirement: CB-003 - Domain Blocking

The system SHALL block navigation to domains matched by `||domain^` rules using O(1) hash set lookups, for both main-document navigations and sub-resource requests. Path-anchored rules (`||domain^/path`, `||domain^*glob`) extend the same domain hash hit with a per-domain regex check against the URL's path. Exception domains (`@@||domain^`) override blocked domains.

#### Scenario: Exact domain match

**Given** `tracker.net` is in the blocked domains set
**When** the webview navigates to `https://tracker.net/path`
**Then** navigation is cancelled

#### Scenario: Subdomain blocked by parent

**Given** `tracker.net` is in the blocked domains set
**When** the webview navigates to `https://sub.tracker.net/path`
**Then** navigation is cancelled (parent domain walk-up matches)

#### Scenario: No partial string match

**Given** `tracker.net` is in the blocked domains set
**When** the webview navigates to `https://mytracker.net/path`
**Then** navigation is allowed (`mytracker.net` is not a subdomain of `tracker.net`)

#### Scenario: Exception domain overrides block

**Given** `tracker.net` is in the blocked domains set
**And** `cdn.tracker.net` is in the exception domains set
**When** the webview navigates to `https://cdn.tracker.net/resource.js`
**Then** navigation is allowed (exception overrides block)

#### Scenario: Exception domain with subdomain walk-up

**Given** `tracker.net` is in the blocked domains set
**And** `cdn.tracker.net` is in the exception domains set
**When** the webview navigates to `https://sub.cdn.tracker.net/resource.js`
**Then** navigation is allowed (parent domain walk-up finds exception)

#### Scenario: Exception does not affect unrelated subdomains

**Given** `tracker.net` is in the blocked domains set
**And** `cdn.tracker.net` is in the exception domains set
**When** the webview navigates to `https://other.tracker.net/path`
**Then** navigation is cancelled (exception only covers cdn.tracker.net)

#### Scenario: Hook ordering

**Given** a URL in shouldOverrideUrlLoading
**Then** the content blocker check runs after captcha allowlist and DNS blocklist, before ClearURLs processing

#### Scenario: Sub-resource domain blocking (Android)

**Given** `ads.example.com` is in the ABP blocked domains set
**And** an enabled filter list contains `||ads.example.com^`
**When** a page on another origin issues an `<img src="https://ads.example.com/banner.png">` sub-resource request
**Then** the native `FastSubresourceInterceptor` cancels the request before it reaches the network
**And** the per-site block log records the event with source `abp`

#### Scenario: Sub-resource domain blocking (iOS/macOS)

**Given** the ABP blocklist contains `tracker.example.com`
**And** the merged DNS+ABP Bloom filter has been delivered to the webview's JS interceptor
**When** the page issues a `fetch('https://tracker.example.com/beacon')` call
**Then** the Bloom prefilter identifies the host as "possibly blocked"
**And** the Dart `blockCheck` handler confirms the block via `ContentBlockerService.isBlocked`
**And** the request is rejected with `TypeError: Blocked by DNS blocklist`
**And** the per-site block log records the event with source `abp`

#### Scenario: Source attribution when domain appears in both lists

**Given** `doubleclick.net` is in both the DNS blocklist and the ABP blocklist
**When** a sub-resource request to `doubleclick.net` is blocked
**Then** the interceptor attributes the hit to `dns` (DNS is checked first)
**And** the ABP block counter is not incremented for that request

#### Scenario: Path-anchored rule blocks matching URL

**Given** the filter list contains `||example.com/ads/`
**When** the webview navigates to `https://example.com/ads/banner.png`
**Then** navigation is cancelled
**When** the webview navigates to `https://example.com/news/`
**Then** navigation is allowed

#### Scenario: Path-anchored rule walks up to parent domain

**Given** `||example.com/track` is registered against `example.com`
**When** a sub-resource request goes to `https://cdn.example.com/track/x`
**Then** the request matches the parent-domain glob (`cdn.example.com` walks up to `example.com`)

#### Scenario: Path-anchored rule honours exception domains

**Given** the filter list contains `||example.com/ads/` and `@@||example.com^`
**When** the webview navigates to `https://example.com/ads/banner.png`
**Then** the request is allowed (exception overrides path-anchored block)

#### Scenario: isHostBlocked ignores path rules

**Given** a path-anchored rule exists for `example.com` but no whole-domain rule
**When** the host-only fast path (`isHostBlocked('example.com')`) is consulted
**Then** it returns `false` — path matching requires the URL's path, which isn't available at this layer

#### Scenario: Per-source counters preserved in stats

**Given** a page load produces 10 DNS-blocked sub-resources and 3 ABP-blocked sub-resources
**Then** `DnsStats.blocked` equals 13 (merged)
**And** `DnsStats.blockedByDns` equals 10
**And** `DnsStats.blockedByAbp` equals 3
**And** the stats banner displays `13 blocked`

---

### Requirement: CB-004 - CSS Cosmetic Filtering

The system SHALL hide page elements by injecting CSS `display: none !important` rules, applied before content renders. uBO `:style(declarations)` rules are emitted as ordinary CSS rules (`selector { declarations }`) in the same `<style>` tag, without the `display:none` decoration.

#### Scenario: Early CSS injection via UserScript

**Given** cosmetic selectors exist for a page
**When** the webview starts loading the page
**Then** a `<style>` tag with `display: none !important` rules is injected at `DOCUMENT_START` via `initialUserScripts`
**And** elements matching the selectors are never visually rendered

#### Scenario: CSS injection on navigation

**Given** a webview navigates to a new page within the same tab
**When** `onLoadStart` fires
**Then** the early CSS script is re-injected for the new URL's applicable selectors

#### Scenario: One rule per selector for resilience

**Given** cosmetic selectors include one invalid selector among many valid ones
**When** the CSS is injected
**Then** the CSS parser silently discards the invalid rule and applies every other valid rule in the same `<style>` tag

#### Scenario: Selector hides rely entirely on the early `<style>` tag

**Given** cosmetic selectors are applicable to a page
**When** the cosmetic shim runs
**Then** there is no runtime `querySelectorAll` sweep for selector matches; the browser's CSS engine is the sole hide mechanism (verified by `test/js/content_blocker_shim_equivalence.test.js`, `test/browser/content_blocker_shim_equivalence.test.js`)

#### Scenario: Late-added or class-flipped elements hide reactively

**Given** the early `<style>` tag is installed at `DOCUMENT_START`
**When** a matching element is appended to the DOM after page load, OR an existing element gains a matching class/attribute later
**Then** the CSS engine re-matches automatically and the element is hidden — including the class-flip case the prior runtime sweep could not catch (its `MutationObserver` opted into `childList` only, not attributes)

#### Scenario: `:has()` selectors hide reactively when descendants change

**Given** a `:has()` selector (either a native rule or one rewritten from `:-abp-has()`) is applied to the page
**When** a matching descendant is added to a candidate parent after page load
**Then** the parent is hidden by the CSS engine without any JS work

#### Scenario: MutationObserver runs only for text-content rules

**Given** a page has cosmetic selectors but no text-hide rules
**When** the cosmetic shim runs
**Then** no `MutationObserver` is installed (selector hides are handled entirely by the CSS engine)

**Given** a page has text-hide rules
**When** new DOM nodes are inserted
**Then** a debounced `MutationObserver` re-runs the text scan within 50ms — selector hides remain owned by the CSS engine

#### Scenario: uBO `:style()` rule applies custom declarations

**Given** a rule `##.banner:style(height: 1px !important)`
**When** the page is loaded
**Then** the early `<style>` tag contains `.banner { height: 1px !important }`
**And** the matching element's computed `height` is `1px`
**And** the element's computed `display` is NOT `none`

#### Scenario: uBO `:style()` rule rides domain scoping

**Given** a rule `linkedin.com##.promo:style(opacity: 0.1)`
**When** the user visits `https://linkedin.com`
**Then** the `<style>` tag contains the rule
**When** the user visits `https://other.com`
**Then** the rule is NOT in the `<style>` tag

#### Scenario: Domain-scoped selectors

**Given** a selector `example.com##.ad-box` is loaded
**When** the user visits `https://example.com/page`
**Then** `.ad-box` is hidden
**When** the user visits `https://other.com/page`
**Then** `.ad-box` is NOT hidden (not a global selector)

---

### Requirement: CB-005 - Text-Based Hiding

The system SHALL hide elements containing specific text patterns, for `#?#` rules with `:-abp-contains()`.

#### Scenario: Hide LinkedIn promoted posts

**Given** a text hide rule targets `linkedin.com` with selector `div.feed-shared-update-v2` and pattern `Promoted`
**When** the user views their LinkedIn feed
**Then** posts containing "Promoted" in their text content are hidden

#### Scenario: Multiple text patterns

**Given** a text hide rule has patterns `["Promoted", "Sponsored"]`
**When** an element's `textContent` contains either pattern
**Then** the element is hidden

#### Scenario: Text hiding with MutationObserver

**Given** the page dynamically loads more content (infinite scroll)
**When** new elements matching the selector appear
**Then** text-based hiding is applied within 50ms

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

#### Scenario: Toggle disabled when no rules

**Given** no filter lists have been downloaded
**When** the user opens site settings
**Then** the Content Blocker toggle is greyed out (disabled)

#### Scenario: Propagates to nested webviews

**Given** a site has content blocking enabled
**When** a cross-domain link opens in a nested InAppBrowser
**Then** the nested webview also has content blocking enabled

---

### Requirement: CB-007 - License Attribution

The EasyList filter lists SHALL be credited under CC BY-SA 3.0 in the app's license page and README.

#### Scenario: License visible

**Given** the user opens the Licenses page
**Then** an entry for "EasyList filter lists (filter data)" is shown
**And** it displays the CC BY-SA 3.0 license text crediting "The EasyList authors"

#### Scenario: README attribution

**Given** a user reads the README
**Then** EasyList is listed in the Tech Stack section with license info

---

### Requirement: CB-008 - Native Interceptor Synchronization

Whenever the aggregated ABP rule set changes (download, toggle, remove, add custom list), the system SHALL re-push the current `ContentBlockerService.blockedDomains` set to the native Android interceptor and invalidate the merged DNS+ABP JS Bloom filter.

#### Scenario: Rules change fires listener

**Given** a caller has subscribed via `ContentBlockerService.addRulesChangedListener`
**When** any of `downloadList`, `downloadAllLists`, `toggleList`, `removeList`, `addCustomList`, or `initialize` completes
**Then** `_rebuildRules` runs and invokes the listener after the aggregated sets are updated

#### Scenario: Main wiring pushes to native and invalidates Bloom

**Given** app startup has registered `ContentBlockerService.addRulesChangedListener`
**When** the listener fires
**Then** `WebInterceptNative.sendAbpDomains` is called with the current blocked-domains set (Android only; no-op on other platforms)
**And** `DnsBlockService.invalidateMergedBloom` clears the cached Bloom so the next webview creation rebuilds it

#### Scenario: Initial sync on startup

**Given** cached filter lists include 50,000 blocked domains at startup
**When** `ContentBlockerService.initialize` completes
**Then** main.dart explicitly calls `WebInterceptNative.sendAbpDomains` once
**And** the listener is registered afterwards so subsequent changes re-sync automatically

---

### Requirement: CB-009 - Backward Compatibility

Existing sites without `contentBlockEnabled` in their stored JSON SHALL default to `true` on deserialization.

#### Scenario: Upgrade from older version

**Given** a user upgrades from a version without content blocking
**When** their sites are loaded from SharedPreferences
**Then** all sites have `contentBlockEnabled: true`

---

## Implementation Details

### Architecture: Why Not flutter_inappwebview ContentBlocker

The `flutter_inappwebview` plugin provides a `contentBlockers` parameter on `InAppWebViewSettings` that maps to platform-specific implementations:

**iOS/macOS (WebKit):** Rules are compiled into `WKContentRuleList` bytecode via `WKContentRuleListStore.compileContentRuleList()`. This runs at the WebKit engine level before resources load — fast and efficient. Supports `block`, `block-cookies`, `css-display-none`, and `ignore-previous-rules` actions.

**Android (No native API):** The plugin implements content blocking in Java:
- Resource blocking: Each `block` rule is checked via `Pattern.matcher(url).matches()` inside `shouldInterceptRequest()`. With 30K+ EasyList rules, this is O(n) per sub-resource request, causing page load timeouts.
- CSS hiding: All `css-display-none` selectors are concatenated into a single JS string and injected via `evaluateJavascript()` with a hardcoded 800ms `Handler.postDelayed()`. No `MutationObserver` — dynamic content in React/SPA apps is never caught.
- `IGNORE_PREVIOUS_RULES`: The `ContentBlockerActionType.IGNORE_PREVIOUS_RULES` static field throws `type 'Null' is not a subtype of type 'String'` on non-Apple platforms because the native value mapping is null.

Our custom implementation avoids these issues:
- O(1) domain blocking via hash set (vs O(n) regex per request)
- CSS injection at `DOCUMENT_START` via `UserScript` (vs 800ms delayed `evaluateJavascript`)
- Selector hides handled entirely by the early `<style>` tag — the CSS engine matches present and future elements, including class-flips and `:has()` descendant changes, with zero JS cost on every keystroke
- `MutationObserver` (50ms debounce) installed only when text-content rules are present, to re-run text-scan on dynamic inserts
- Text-based hiding for `:-abp-contains()` patterns (not supported by ContentBlocker API at all)
- Cross-platform: same behavior on iOS, Android, and macOS

### ABP Filter Parser

`AbpParseResult parseAbpFilterListSync(String content)` parses a filter list into three data structures:

```dart
class AbpParseResult {
  final Set<String> blockedDomains;                    // ||domain^ rules
  final Set<String> exceptionDomains;                  // @@||domain^ rules
  final Map<String, List<String>> cosmeticSelectors;   // ## rules (key '' = global)
  final Map<String, List<TextHideRule>> textHideRules; // #?# rules with :-abp-contains
}

class TextHideRule {
  final String selector;          // CSS selector for container element
  final List<String> textPatterns; // Text patterns to match in textContent
}
```

Parsing is run in a background isolate via `compute()` to avoid blocking the UI.

Rule type support:

| Syntax | Support | Notes |
|--------|---------|-------|
| `\|\|domain^` | Converted to blocked domain | Simple domain-only patterns |
| `\|\|domain^$options` | Converted (options ignored) | Domain extracted, options skipped |
| `@@\|\|domain^` | Converted to exception domain | Overrides blocked domains |
| `##selector` | Converted to cosmetic selector | Including standard CSS `:has()` |
| `domain##selector` | Converted with domain scope | Multiple domains via `d1,d2##sel` |
| `##sel:-abp-has(X)` | Rewritten to `sel:has(X)` | Standard CSS `:has()` |
| `##sel:has-text(text)` | Converted to TextHideRule | Text-based element hiding |
| `##sel:contains(text)` | Converted to TextHideRule | Alias for `:has-text()` |
| `#?#sel:-abp-contains(text)` | Converted to TextHideRule | Extracts selector + text patterns |
| `#?#sel:-abp-contains(/a\|b/)` | Converted to TextHideRule | Regex-style patterns split on `\|` |
| `#$#` snippet filters | Skipped | Would require ABP snippet runtime |
| `##^` HTML filters | Skipped | Non-standard |
| `@@\|\|domain/path` | Skipped | Only simple domain exceptions supported |
| `$redirect`, `$csp`, `$removeparam` | Skipped | Advanced modifiers |
| `/regex/` patterns | Skipped | Resource-level regex |
| `:matches-path()`, `:matches-attr()` | Skipped in `##` | Unsupported pseudo-classes |

### ContentBlockerService Singleton

```dart
static ContentBlockerService? _instance;
static ContentBlockerService get instance => _instance ??= ContentBlockerService._();
```

Key methods:
- `isBlocked(url)` — O(1) domain lookup with parent domain walk-up; exception domains checked first
- `getEarlyCssScript(pageUrl)` — Returns JS that injects a `<style>` tag (for DOCUMENT_START)
- `getCosmeticScript(pageUrl)` — Returns full JS with MutationObserver + text hiding (for onLoadStop)

Aggregated state:
- `_blockedDomains: Set<String>` — union of all enabled lists' blocked domains
- `_exceptionDomains: Set<String>` — union of all enabled lists' exception domains (override blocks)
- `_cosmeticSelectors: Map<String, List<String>>` — union of all enabled lists' CSS selectors
- `_textHideRules: Map<String, List<TextHideRule>>` — union of all enabled lists' text rules

### Default Filter Lists

| Name | URL |
|------|-----|
| EasyList | `https://easylist.to/easylist/easylist.txt` |
| EasyPrivacy | `https://easylist.to/easylist/easyprivacy.txt` |
| Fanboy's Social | `https://easylist.to/easylist/fanboy-social.txt` |
| Fanboy's Annoyance | `https://easylist.to/easylist/fanboy-annoyance.txt` |

All licensed under GPL-3.0 / CC BY-SA 3.0 (dual-licensed, used under CC BY-SA 3.0).

### FilterList Data Model

```dart
class FilterList {
  final String id;
  final String name;
  final String url;
  bool enabled;
  int ruleCount;
  DateTime? lastUpdated;
}
```

Serialized to/from JSON, stored in SharedPreferences as a JSON string.

### Cosmetic Script Injection

Two-phase injection:

1. **DOCUMENT_START** (via `initialUserScripts` + `onLoadStart`): CSS-only script that creates a `<style>` tag with `display: none !important` rules. Prevents flash of unstyled content. Owns the entire selector-hide path — including selectors rewritten from `:-abp-has()` to standard CSS `:has()`, which the CSS engine re-evaluates reactively when descendants change.

2. **onLoadStop**: Full script that re-asserts the same `<style>` tag (idempotent) and, when text-hide rules are present:
   - `hideText()` function that walks elements matching each rule's selector and writes `display: none` inline when any pattern is found in `textContent`
   - `MutationObserver` on `document.body` with 50ms debounced callback that re-runs `hideText()`. The observer is **not** installed when no text-hide rules apply, since selector hides are owned by the CSS engine.

Equivalence between this CSS-only shape and the previous shape (which also ran a runtime `querySelectorAll` sweep writing inline `style.display = 'none'`) is asserted at computed-style level by `test/js/content_blocker_shim_equivalence.test.js` and `test/browser/content_blocker_shim_equivalence.test.js`.

### Hook Point in WebView

Main-document domain blocking in `shouldOverrideUrlLoading`:

```dart
shouldOverrideUrlLoading: (controller, navigationAction) async {
  final url = navigationAction.request.url.toString();
  if (_shouldBlockUrl(url)) return CANCEL;
  if (isCaptchaChallenge(url)) return ALLOW;
  // DNS check records stats with source: BlockSource.dns on hit
  if (config.dnsBlockEnabled && DnsBlockService.instance.isBlocked(url)) return CANCEL;
  // Content blocker domain check — records stats with source: BlockSource.abp on hit
  if (config.contentBlockEnabled && ContentBlockerService.instance.isBlocked(url)) {
    return CANCEL;
  }
  // ClearURLs processing...
}
```

### Sub-resource Domain Blocking Integration

ABP's `||domain^` rules extend beyond main-document navigation into every sub-resource request, by feeding the same aggregated set to the shared sub-resource interceptor used by the DNS blocklist.

**Android (native):** `WebInterceptPlugin.kt` maintains two parallel hash sets, `dnsBlockedDomains` and `abpBlockedDomains`. `FastSubresourceInterceptor.checkUrl` tries DNS first (with hierarchy walk-up), then ABP. On match it calls `onBlockChecked(host, true, "dns"|"abp")`, which the Dart bridge drains via `fetchBlockEvents` and records on `DnsBlockService` with the right `BlockSource`.

**iOS/macOS (JS):** A single merged Bloom filter built from DNS ∪ ABP blocked domains is shipped to the JS interceptor via the `getBlockBloom` handler. The JS layer wraps `fetch`, `XMLHttpRequest`, and property setters on `img/script/link/iframe`; a Bloom match triggers the `blockCheck` roundtrip, which in Dart resolves DNS vs ABP (respecting the per-site `dnsBlockEnabled` and `contentBlockEnabled` toggles) and records the decision.

Both paths feed the same `DnsBlockService.DnsStats` structure so the stats banner and dev-tools DNS tab show a single merged "blocked" count while `blockedByDns` / `blockedByAbp` remain separately countable. When one filter list ships a domain that also appears in the DNS blocklist, the DNS side wins attribution (it's checked first).

### Storage

- Filter list files: `getApplicationDocumentsDirectory()/content_blocker/<id>.txt`
- List metadata: SharedPreferences key `content_blocker_lists` (JSON string)

### WebViewModel Integration

`contentBlockEnabled` field added to `WebViewModel`:
- Constructor default: `true`
- Serialized to JSON as `'contentBlockEnabled'`
- Deserialized with `?? true` fallback for backward compatibility
- Passed through to `WebViewConfig.contentBlockEnabled`
- Propagated to nested InAppBrowser via `launchUrlFunc`

---

## Files

### Created
- `lib/services/abp_filter_parser.dart` — ABP filter list parser: domain extraction, cosmetic selectors, text hide rules
- `lib/services/content_blocker_service.dart` — Singleton service: list management, download, cache, rule aggregation, script generation
- `test/abp_filter_parser_test.dart` — 24 unit tests for parser
- `test/content_blocker_service_test.dart` — 11 unit tests for service
- `openspec/specs/content-blocker/spec.md` — This specification

### Modified
- `lib/web_view_model.dart` — Added `contentBlockEnabled` field, serialization, pass to WebViewConfig
- `lib/services/webview.dart` — Added `contentBlockEnabled` to WebViewConfig, domain block hook, UserScript CSS injection at DOCUMENT_START, cosmetic script injection at onLoadStop, merged DNS+ABP JS Bloom interceptor, source-tagged stat recording
- `lib/services/content_blocker_service.dart` — Public `blockedDomains` getter, `addRulesChangedListener`/`removeRulesChangedListener` for native + JS Bloom sync
- `lib/services/dns_block_service.dart` — `BlockSource` enum, source field on `DnsLogEntry`, `blockedByDns`/`blockedByAbp` counters, `getMergedBlockBloom` for DNS ∪ ABP, blocklist-changed listeners
- `lib/services/web_intercept_native.dart` — `sendDnsDomains` + `sendAbpDomains` split, source-tagged block events drained via `fetchBlockEvents`
- `android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebInterceptPlugin.kt` — Split DNS/ABP domain sets, source-tagged block events, renamed method channel handlers to `setDnsBlockedDomains` / `setAbpBlockedDomains` / `fetchBlockEvents` / `blockEventsReady`
- `lib/widgets/stats_banner.dart` — Shows banner when either DNS or ABP has populated domain sets
- `lib/screens/settings.dart` — Per-site Content Blocker toggle (SwitchListTile)
- `lib/screens/app_settings.dart` — Content Blocker section with list management UI, download/toggle/remove, custom list dialog
- `lib/screens/inappbrowser.dart` — Propagate `contentBlockEnabled` to nested webview
- `lib/main.dart` — ContentBlockerService initialization, change-listener wiring for native + Bloom sync, CC BY-SA 3.0 license registration
- `test/web_view_model_test.dart` — Tests for contentBlockEnabled serialization and defaults
- `README.md` — Feature bullet point, Tech Stack credit with license info
- `fastlane/metadata/android/en-US/changelogs/9.txt` — Changelog entry

---

## Testing

### Unit Tests

```bash
# ABP filter parser tests (rule parsing, selector handling, text rules)
fvm flutter test test/abp_filter_parser_test.dart

# Content blocker service tests (FilterList serialization, domain blocking, script generation)
fvm flutter test test/content_blocker_service_test.dart

# WebViewModel serialization tests (contentBlockEnabled field)
fvm flutter test test/web_view_model_test.dart
```

ABP filter parser tests cover:
- Comment and header line skipping
- Simple domain block rule conversion (`||domain^`)
- Domain rule without trailing `^`
- Simple exception rule conversion (`@@||domain^`)
- Complex exception rule skipping (`@@||domain/path`)
- Exception domain case-insensitivity
- Global cosmetic filter conversion (`##.selector`)
- Domain-specific cosmetic filter conversion (`domain##.selector`)
- Multi-domain cosmetic filter
- Standard CSS `:has()` selectors (allowed — native CSS)
- `:has-text()` in `##` rules converted to text hide rules
- `:contains()` in `##` rules converted to text hide rules
- `:-abp-has()` rewritten to standard `:has()` in cosmetic rules
- Domain-specific `:-abp-has()` rewriting
- `#?#` rules with `:-abp-contains()` to text hide rules
- `#?#` rules without text matching (skipped)
- `#$#` snippet rules (skipped)
- `##^` HTML filter rules (skipped)
- Complex path rules (skipped — not domain-only)
- `$redirect`, `$csp`, `$removeparam` rules (skipped)
- Regex patterns (skipped)
- Mixed rule parsing (domains, exceptions, cosmetic, :-abp-has, :has-text)
- Real EasyList-style rules
- Case-insensitive domain blocking
- Selector aggregation from multiple rules

Content blocker service tests cover:
- FilterList JSON serialization/deserialization
- Optional field handling
- JSON round-trip
- List-of-lists serialization
- Singleton instance
- hasRules state
- totalRuleCount across enabled lists
- Unmodifiable list getter
- isBlocked with domain hierarchy walk-up
- isBlocked respects exception domains (subdomain exception, unrelated subdomains still blocked)
- isBlocked with exception on exact blocked domain
- getCosmeticScript returns null when no selectors

### Manual Testing

1. Open App Settings, scroll to Content Blocker section
2. Tap download on EasyList, verify rule count appears
3. Tap "Update All", verify all lists download
4. Open a site with ads (e.g., a news site), verify ad elements are hidden
5. Open LinkedIn, verify "Promoted" posts are hidden in feed
6. Open site Settings, disable Content Blocker toggle, reload page
7. Verify ads and promoted content reappear
8. Add a custom filter list via "Add Custom List" dialog
9. Verify the custom list can be downloaded, toggled, and removed
10. Check Licenses page shows "EasyList filter lists (filter data)" with CC BY-SA 3.0
11. Restart app, verify filter lists are loaded from cache and blocking works immediately
