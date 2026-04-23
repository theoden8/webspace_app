# Per-Site Language Specification

## Status
**Implemented**

## Purpose

Allow users to choose, per site, the language content should be served in —
independent of the Android/iOS/macOS system locale. The app communicates the
preference to both sides of a modern web page:

1. **Server-side:** an `Accept-Language` request header for content negotiation.
2. **Client-side:** a `DOCUMENT_START` user script that overrides
   `navigator.language`, `navigator.languages`, and
   `Intl.DateTimeFormat.prototype.resolvedOptions` so JS-driven locale
   resolvers (React i18n, SPA framework detection, date/number formatters)
   see the per-site tag instead of the OS locale.

The preference is a hint. Sites are not forced into the chosen language — they
may lack a translation, may route via URL path (`/en/`, `/es/`), or may ignore
both the header and the JS APIs. This spec documents the hints the app sends,
not what sites do with them.

## Problem Statement

Before the client-side override existed, the Accept-Language header was the
only signal. Client-rendered SPAs (for example Bluesky) read
`navigator.languages` at startup to pick a UI locale and ignored the header
entirely, so the app's per-site language setting had no effect on them even
after a full data wipe. The user's selected language on-site came from the
Android system language instead, making the app feel dependent on system
settings. Adding a `navigator.language` override at `DOCUMENT_START` closes
that gap.

---

## Requirements

### Requirement: LANG-001 - Accept-Language Header

The app SHALL send the user's per-site language preference as the
`Accept-Language` HTTP header on top-level navigations from that webview.

The header format is `{tag}, *;q=0.5`, where `{tag}` is a BCP-47 /
ISO 639-1 code (for example `en`, `es`, `fr`). The `*;q=0.5` fallback
signals that any language is acceptable at lower priority.

When the user has not chosen a language for a site, no custom header is sent
and the platform default is used.

#### Scenario: Request content in Spanish

**Given** the user selects Spanish (`es`) for a site
**When** the webview loads any top-level URL for that site
**Then** the request includes header `Accept-Language: es, *;q=0.5`
**And** the server may respond with Spanish content if available

#### Scenario: System default language

**Given** the user has not selected a specific language for a site
**When** the webview loads any URL
**Then** no custom `Accept-Language` header is sent
**And** the platform's default language preference is used

---

### Requirement: LANG-002 - Client-Side Locale Override

When a per-site language is set, the app SHALL inject a
`UserScriptInjectionTime.AT_DOCUMENT_START` script that overrides, for the
page and all its inline scripts:

1. `Navigator.prototype.language` — returns the per-site tag
2. `Navigator.prototype.languages` — returns a frozen single-element array
   containing the per-site tag
3. `Intl.DateTimeFormat.prototype.resolvedOptions` — returns the original
   result with `locale` rewritten to the per-site tag

The override MUST run before any of the page's own JavaScript so SPAs picking
a locale at boot observe the override, not the OS value. The script is
omitted entirely when no per-site language is set — the OS values remain
visible.

The tag is interpolated into the script via JSON encoding so that a tag
containing quotes, backslashes, or Unicode characters cannot break out of the
JS string literal.

#### Scenario: SPA observes per-site language

**Given** the user selects Spanish (`es`) for a React-based site
**And** that site reads `navigator.languages` at boot
**When** the page loads
**Then** `navigator.language` is `"es"`
**And** `navigator.languages` is `["es"]`
**And** `new Intl.DateTimeFormat().resolvedOptions().locale` is `"es"`

#### Scenario: No override when unset

**Given** the user has not selected a language for a site
**When** the page loads
**Then** `navigator.language` returns the OS default
**And** no override script is injected

---

### Requirement: LANG-003 - Language Selection UI

The app SHALL provide language selection per site in site settings, offering:

1. A "System default" option (no custom header, no JS override)
2. 30+ BCP-47 / ISO 639-1 language options
3. A per-site — not per-webspace — preference

Saving a language change SHALL dispose the existing webview so it is recreated
on next render with the new `Accept-Language` header and the new override
script.

#### Scenario: Change site language

**Given** a site is displaying in English
**When** the user selects Spanish in site settings and saves
**Then** the existing webview is disposed
**And** the next render creates a new webview with the Spanish
  `Accept-Language` header
**And** the `DOCUMENT_START` override script sees `es`
**And** the site reloads; where supported, content appears in Spanish

---

### Requirement: LANG-004 - Preference Persistence

Per-site language preference SHALL persist across app restarts, carried on
`WebViewModel.toJson()` like other per-site settings, and SHALL be included
in settings backup/import via the `sites` array.

#### Scenario: Restore preference on restart

**Given** the user set Spanish for a site
**When** the app is closed and reopened
**Then** the site's language is still Spanish
**And** the next webview creation sends `Accept-Language: es, *;q=0.5`
**And** injects the override script with tag `es`

---

### Requirement: LANG-005 - Cross-Platform Consistency

The `Accept-Language` header and the client-side override SHALL be applied
identically on all supported platforms (Android, iOS, macOS). No
platform-specific branching is permitted for language handling.

#### Scenario: Same behavior across platforms

**Given** the same site with the same per-site language
**When** the site is opened on Android, iOS, or macOS
**Then** the `Accept-Language` header is identical on all three
**And** `navigator.language` inside the page returns the same value on all three

---

## Data Model

```dart
class WebViewModel {
  String? language; // BCP-47 tag (e.g., 'en', 'es'), null = system default
}

class WebViewConfig {
  final String? language; // Threaded through to the webview on creation
}

abstract class WebViewController {
  Future<void> loadUrl(String url, {String? language});
}
```

---

## Implementation Details

### Accept-Language Header

Emitted by:
- `WebViewFactory.createWebView` — sets the header on the initial `URLRequest`
  when `config.language != null`.
- `_WebViewController.loadUrl` — sets the header on subsequent programmatic
  navigations when a language is passed.

Format: `'{language}, *;q=0.5'`, e.g. `Accept-Language: es, *;q=0.5`.

### Client-Side Override Script

`_languageOverrideScript(tag)` builds a small IIFE injected at
`UserScriptInjectionTime.AT_DOCUMENT_START` via `inapp.UserScript` with
group name `language_override`. The script:

```dart
String _languageOverrideScript(String language) {
  final encoded = jsonEncode(language);
  return '''
(function() {
  try {
    var lang = $encoded;
    var langs = Object.freeze([lang]);
    Object.defineProperty(Navigator.prototype, 'language', {
      configurable: true, get: function() { return lang; }
    });
    Object.defineProperty(Navigator.prototype, 'languages', {
      configurable: true, get: function() { return langs; }
    });
    if (typeof Intl !== 'undefined' && Intl.DateTimeFormat) {
      var proto = Intl.DateTimeFormat.prototype;
      var orig = proto.resolvedOptions;
      proto.resolvedOptions = function() {
        var r = orig.apply(this, arguments);
        r.locale = lang;
        return r;
      };
    }
  } catch (e) {}
})();
''';
}
```

Design notes:

- The properties are defined on `Navigator.prototype`, not on the `navigator`
  instance, because some WebView builds (notably older WebKit) treat the
  instance accessors as non-configurable.
- The `languages` array is frozen so callers that try to push/splice into it
  don't silently mutate shared state.
- The function is wrapped in `try {}` so a failure in one override (for
  example if `Intl` is absent on a stripped-down engine) does not block the
  others.
- The JS source is followed by `\n;null;` when attached to `UserScript` to
  satisfy `evaluateJavascript`-style return-value handling.

### Propagation on Settings Save

`SettingsScreen` assigns `widget.webViewModel.language = _selectedLanguage`,
then calls `widget.webViewModel.disposeWebView()`. The parent rebuilds the
webview with a `UniqueKey`, so `WebViewFactory.createWebView` runs again and
re-creates both the header and the user script with the new tag.

---

## Browser Compatibility

**Sites that benefit from the client-side override:**

- Single-page apps that call `navigator.languages` at boot (React-based
  webapps such as Bluesky, many modern social apps)
- Sites using `Intl.DateTimeFormat` / `Intl.NumberFormat` without an explicit
  locale argument

**Sites that benefit from the header only:**

- Server-rendered multilingual sites (Wikipedia, DuckDuckGo, Google, etc.)
- CDNs and origins that content-negotiate on `Accept-Language`

**Sites unaffected by either hint:**

- Sites using URL-based language selection (`/en/`, `/es/`), which typically
  overrides the header for their internal routing
- Sites with a single translation
- Sites that read the language from an auth profile or a cookie

---

## Limitations

- **Top-level requests only:** the custom `Accept-Language` header is applied
  to the initial URL request and to `loadUrl(...)`-driven navigations. Sub-
  resource requests (XHR, fetch, sub-iframes) go through the platform
  networking stack with the OS `Accept-Language`. Sites that re-fetch locale
  bundles over XHR without respecting the JS APIs may still see the OS tag
  for those specific requests.
- **Suggestion, not override:** the chosen language is a hint. A site may
  lack a translation, may force a locale via its own logic, or may ignore
  both the header and the JS APIs.
- **Not retroactive within a session:** changing the language disposes the
  webview so the override runs on the next creation. Existing long-lived
  webviews would otherwise not pick up the new tag.

---

## Files

- `lib/services/webview.dart` — `Accept-Language` header emission,
  `_languageOverrideScript`, `UserScript` registration
- `lib/web_view_model.dart` — `language` field and serialization
- `lib/main.dart` — language threaded into `WebViewConfig` and `loadUrl`
- `lib/screens/settings.dart` — language selection UI
- `lib/demo_data.dart` — demo language defaults
