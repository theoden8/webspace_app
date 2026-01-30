# Webview Hints Specification

## Purpose

The app provides hints to webviews about user preferences for display and content. These hints include:
1. **Theme preference** (light/dark mode) - Suggests visual theme via JavaScript
2. **Language preference** - Requests content in preferred language via Accept-Language header

These are hints/suggestions to websites, not forced overrides. Websites may choose to respect or ignore them.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: HINTS-001 - Theme Preference

The app SHALL suggest its current theme mode (light, dark, or system) to webviews.

#### Scenario: Apply dark theme hint

**Given** the app is set to dark mode
**When** a webview is created
**Then** the webview receives the dark theme preference via JavaScript injection

---

### Requirement: HINTS-002 - JavaScript Theme Injection

Theme preference SHALL be applied to webviews via JavaScript injection that:
1. Overrides `window.matchMedia` to intercept `prefers-color-scheme` queries
2. Sets the `<meta name="color-scheme">` tag in the page's `<head>`
3. Sets `color-scheme` CSS property on `document.documentElement`
4. Maintains theme change listeners for dynamic updates

#### Scenario: Inject dark mode preference

**Given** the app is in dark mode
**When** a page loads
**Then** JavaScript sets `<meta name="color-scheme" content="dark">`
**And** sets `document.documentElement.style.colorScheme = 'dark'`
**And** `window.matchMedia('(prefers-color-scheme: dark)')` returns `{ matches: true }`

---

### Requirement: HINTS-003 - Language Preference via Accept-Language

The app SHALL send language preferences to webviews via the Accept-Language HTTP header.

#### Scenario: Request content in Spanish

**Given** the user selects Spanish (es) for a site
**When** the webview loads any URL
**Then** the request includes header `Accept-Language: es, *;q=0.5`
**And** the server may respond with Spanish content if available

#### Scenario: System default language

**Given** the user has not selected a specific language
**When** the webview loads any URL
**Then** no custom Accept-Language header is sent
**And** the system's default language preference is used

---

### Requirement: HINTS-004 - Language Selection UI

The app SHALL provide language selection in site settings with:
1. System default option (no custom header)
2. 30+ language options
3. Per-site language preference (not per-workspace)

#### Scenario: Change site language

**Given** a site is displaying in English
**When** the user selects Spanish in site settings and saves
**Then** the webview recreates with Spanish Accept-Language header
**And** the site reloads showing Spanish content (if supported)

---

### Requirement: HINTS-005 - Hint Application Timing

Theme and language hints SHALL be applied:
1. On webview creation (initial load with Accept-Language, theme on controller ready)
2. On page navigation (theme reapplied after each page load)
3. On theme toggle (immediately to all existing webviews)
4. On language change (webview recreated with new Accept-Language)
5. On app startup (to all restored webviews)

#### Scenario: Apply theme on toggle

**Given** multiple webviews are open
**When** the user toggles from light to dark mode
**Then** all webviews immediately receive the dark theme preference

#### Scenario: Apply language on settings save

**Given** a webview is displaying content
**When** the user changes language and saves settings
**Then** the webview recreates with UniqueKey
**And** loads current URL with new Accept-Language header

---

### Requirement: HINTS-006 - Preference Persistence

Theme and language preferences SHALL persist across app restarts.

#### Scenario: Restore preferences on restart

**Given** the user set dark mode and Spanish language for a site
**When** the app is closed and reopened
**Then** dark mode is still active
**And** the site's language is still Spanish
**And** all hints are reapplied to webviews

---

### Requirement: HINTS-007 - Cross-Platform Consistency

Hint mechanisms SHALL work on all supported platforms.

#### Scenario: Hints work on Android and Linux

**Given** the same webview content
**When** hints are applied on Android
**And** hints are applied on Linux
**Then** both platforms inject the same preferences

---

## Data Model

```dart
enum WebViewTheme {
  light,
  dark,
  system,
}

class WebViewModel {
  String? language; // Language code (e.g., 'en', 'es'), null = system default
}

class WebViewConfig {
  final String? language; // Language code for Accept-Language header
}

abstract class WebViewController {
  Future<void> setThemePreference(WebViewTheme theme);
  Future<void> loadUrl(String url, {String? language});
}
```

---

## Browser Compatibility

### Theme Hints

**Websites That Support Theme Hints:**
- Modern web apps with dark mode (GitHub, VS Code Web, etc.)
- Sites using CSS `prefers-color-scheme` media queries
- Progressive web apps with proper color-scheme meta tags

**Websites That Don't Support Theme Hints:**
- Legacy sites without dark mode
- Sites with forced light theme in CSS
- Sites that ignore color-scheme preferences

### Language Hints

**Websites That Support Language Hints:**
- Multilingual sites (Wikipedia, DuckDuckGo, Google, etc.)
- Sites that respect Accept-Language header
- Content negotiation-aware servers

**Websites That Don't Support Language Hints:**
- Single-language sites
- Sites using URL-based language selection (/en/, /es/)
- Sites ignoring Accept-Language header

---

## Limitations

### Theme Hints
- **Suggestion only**: This is a *hint* to websites, not forced rendering
- **Site-dependent**: Websites must implement their own dark mode
- **JavaScript required**: Theme application requires JavaScript enabled
- **Best effort**: Some sites may not respond to the preference

### Language Hints
- **Server-dependent**: Sites must respect Accept-Language header
- **Not a guarantee**: Sites may not have content in requested language
- **Per-request**: Each navigation sends the header, but sites control response
- **URL structure**: Some sites use URL paths for language (e.g., /en/, /es/) which overrides header

---

## Implementation Details

### Theme Injection Script

The theme hint is applied via JavaScript that:
1. Intercepts `window.matchMedia` calls for `prefers-color-scheme`
2. Returns appropriate `matches` value based on app theme
3. Maintains listeners for dynamic theme changes
4. Updates color-scheme meta tag and CSS property

### Language Header

The language hint is sent via HTTP header:
```
Accept-Language: es, *;q=0.5
```

Format: `{language}, *;q=0.5` where:
- `{language}` is the ISO 639-1 code (en, es, fr, etc.)
- `*;q=0.5` indicates any language is acceptable with lower priority
- Header is sent on all requests from that webview

---

## Files

### Modified
- `lib/services/webview.dart` - WebViewTheme enum, Accept-Language header, theme injection
- `lib/web_view_model.dart` - Theme state, language field, webview recreation with UniqueKey
- `lib/main.dart` - Theme toggle, language propagation
- `lib/screens/settings.dart` - Language selection UI
- `lib/demo_data.dart` - Demo language defaults
