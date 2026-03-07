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

Three-layer content blocking:

1. **Domain blocking** — O(1) hash set lookup in `shouldOverrideUrlLoading` for `||domain^` rules
2. **CSS cosmetic filtering** — `<style>` tag injection via `UserScript` at `DOCUMENT_START` for `##selector` rules, with `MutationObserver` for dynamic content
3. **Text-based hiding** — JavaScript DOM walking for `#?#` rules with `:-abp-contains()` patterns (e.g., hiding posts containing "Promoted" or "Sponsored")

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

#### Scenario: Skip unsupported rule types

**Given** a filter list containing rules with `#$#` (snippets), `##^` (HTML filters), `$redirect`, `$csp`, `$removeparam`, `@@` (exceptions), or regex patterns
**When** the list is parsed
**Then** these rules are silently skipped

#### Scenario: Skip ABP-only extended CSS

**Given** a filter list containing selectors with `:-abp-has()`, `:has-text()`, `:contains()`, `:matches-path()`, or `:matches-attr()`
**When** the list is parsed
**Then** these selectors are skipped (not standard CSS, would fail in querySelectorAll)

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

The system SHALL block navigation to domains matched by `||domain^` rules using O(1) hash set lookups.

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

#### Scenario: Hook ordering

**Given** a URL in shouldOverrideUrlLoading
**Then** the content blocker check runs after captcha allowlist and DNS blocklist, before ClearURLs processing

---

### Requirement: CB-004 - CSS Cosmetic Filtering

The system SHALL hide page elements by injecting CSS `display: none !important` rules, applied before content renders.

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
**Then** the invalid selector does not affect other selectors (each is a separate CSS rule)

#### Scenario: Batched querySelectorAll

**Given** 100 cosmetic selectors are applicable to a page
**When** the full script runs at `onLoadStop`
**Then** selectors are processed in batches of 20 with per-batch try-catch to prevent one bad selector from breaking all

#### Scenario: MutationObserver for dynamic content

**Given** a React/SPA page that adds new content dynamically after initial load
**When** new DOM nodes are inserted
**Then** the `MutationObserver` triggers cosmetic hiding within 50ms (debounced)

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

### Requirement: CB-008 - Backward Compatibility

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
- `MutationObserver` with 50ms debounce for dynamic content
- Text-based hiding for `:-abp-contains()` patterns (not supported by ContentBlocker API at all)
- Cross-platform: same behavior on iOS, Android, and macOS

### ABP Filter Parser

`AbpParseResult parseAbpFilterListSync(String content)` parses a filter list into three data structures:

```dart
class AbpParseResult {
  final Set<String> blockedDomains;                    // ||domain^ rules
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
| `##selector` | Converted to cosmetic selector | Including standard CSS `:has()` |
| `domain##selector` | Converted with domain scope | Multiple domains via `d1,d2##sel` |
| `#?#sel:-abp-contains(text)` | Converted to TextHideRule | Extracts selector + text patterns |
| `#?#sel:-abp-contains(/a\|b/)` | Converted to TextHideRule | Regex-style patterns split on `\|` |
| `#$#` snippet filters | Skipped | Would require ABP snippet runtime |
| `##^` HTML filters | Skipped | Non-standard |
| `@@` exception rules | Skipped | Not implemented |
| `$redirect`, `$csp`, `$removeparam` | Skipped | Advanced modifiers |
| `/regex/` patterns | Skipped | Resource-level regex |
| `:-abp-has()`, `:has-text()` etc. | Skipped in `##` | ABP-only pseudo-classes |

### ContentBlockerService Singleton

```dart
static ContentBlockerService? _instance;
static ContentBlockerService get instance => _instance ??= ContentBlockerService._();
```

Key methods:
- `isBlocked(url)` — O(1) domain lookup with parent domain walk-up
- `getEarlyCssScript(pageUrl)` — Returns JS that injects a `<style>` tag (for DOCUMENT_START)
- `getCosmeticScript(pageUrl)` — Returns full JS with MutationObserver + text hiding (for onLoadStop)

Aggregated state:
- `_blockedDomains: Set<String>` — union of all enabled lists' blocked domains
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

1. **DOCUMENT_START** (via `initialUserScripts` + `onLoadStart`): CSS-only script that creates a `<style>` tag with `display: none !important` rules. Prevents flash of unstyled content.

2. **onLoadStop**: Full script with:
   - Style tag creation (idempotent, skipped if already exists from phase 1)
   - Batched `querySelectorAll` in groups of 20 with per-batch try-catch
   - `hideText()` function that walks DOM elements and checks `textContent` against patterns
   - `MutationObserver` on `document.body` with 50ms debounced callback

### Hook Point in WebView

Domain blocking in `shouldOverrideUrlLoading`:

```dart
shouldOverrideUrlLoading: (controller, navigationAction) async {
  final url = navigationAction.request.url.toString();
  if (_shouldBlockUrl(url)) return CANCEL;
  if (isCaptchaChallenge(url)) return ALLOW;
  if (config.dnsBlockEnabled && DnsBlockService.instance.isBlocked(url)) return CANCEL;
  // Content blocker domain check
  if (config.contentBlockEnabled && ContentBlockerService.instance.isBlocked(url)) {
    return CANCEL;
  }
  // ClearURLs processing...
}
```

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
- `lib/services/webview.dart` — Added `contentBlockEnabled` to WebViewConfig, domain block hook, UserScript CSS injection at DOCUMENT_START, cosmetic script injection at onLoadStop
- `lib/screens/settings.dart` — Per-site Content Blocker toggle (SwitchListTile)
- `lib/screens/app_settings.dart` — Content Blocker section with list management UI, download/toggle/remove, custom list dialog
- `lib/screens/inappbrowser.dart` — Propagate `contentBlockEnabled` to nested webview
- `lib/main.dart` — ContentBlockerService initialization, CC BY-SA 3.0 license registration
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
- Exception rule skipping (`@@`)
- Global cosmetic filter conversion (`##.selector`)
- Domain-specific cosmetic filter conversion (`domain##.selector`)
- Multi-domain cosmetic filter
- Standard CSS `:has()` selectors (allowed — native CSS)
- ABP-only `:has-text()` selectors (skipped)
- `#?#` rules with `:-abp-contains()` to text hide rules
- `#?#` rules without text matching (skipped)
- `#$#` snippet rules (skipped)
- `##^` HTML filter rules (skipped)
- Complex path rules (skipped — not domain-only)
- `$redirect`, `$csp`, `$removeparam` rules (skipped)
- Regex patterns (skipped)
- Mixed rule parsing
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
