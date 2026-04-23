# Webview Hints Specification

## Purpose

The app provides hints to webviews about user display preferences. Currently
this spec covers theme preference (light/dark mode) suggested via JavaScript
injection.

> **Note:** per-site language preference — which was previously covered here
> as `HINTS-003` / `HINTS-004` — now lives in its own spec at
> [`openspec/specs/language/spec.md`](../language/spec.md). That spec covers
> both the `Accept-Language` header and the client-side
> `navigator.language` / `Intl` override.

Hints are suggestions to websites, not forced overrides. Websites may choose
to respect or ignore them.

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

### Requirement: HINTS-003 - Theme Application Timing

The theme hint SHALL be applied:
1. On webview creation (theme on controller ready)
2. On page navigation (theme reapplied after each page load)
3. On theme toggle (immediately to all existing webviews)
4. On app startup (to all restored webviews)

#### Scenario: Apply theme on toggle

**Given** multiple webviews are open
**When** the user toggles from light to dark mode
**Then** all webviews immediately receive the dark theme preference

---

### Requirement: HINTS-004 - Theme Persistence

Theme preference SHALL persist across app restarts.

#### Scenario: Restore theme on restart

**Given** the user set dark mode
**When** the app is closed and reopened
**Then** dark mode is still active
**And** the theme hint is reapplied to webviews

---

### Requirement: HINTS-005 - Cross-Platform Consistency

The theme hint mechanism SHALL work on all supported platforms.

#### Scenario: Hints work across platforms

**Given** the same webview content
**When** the theme hint is applied on Android, iOS, and macOS
**Then** all platforms inject the same preference

---

## Data Model

```dart
enum WebViewTheme {
  light,
  dark,
  system,
}

abstract class WebViewController {
  Future<void> setThemePreference(WebViewTheme theme);
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

---

## Limitations

### Theme Hints
- **Suggestion only**: This is a *hint* to websites, not forced rendering
- **Site-dependent**: Websites must implement their own dark mode
- **JavaScript required**: Theme application requires JavaScript enabled
- **Best effort**: Some sites may not respond to the preference

---

## Implementation Details

### Theme Injection Script

The theme hint is applied via JavaScript that:
1. Intercepts `window.matchMedia` calls for `prefers-color-scheme`
2. Returns appropriate `matches` value based on app theme
3. Maintains listeners for dynamic theme changes
4. Updates color-scheme meta tag and CSS property

### HTML Cache Theme Prelude

When `HtmlCacheService` returns a cached snapshot for rendering via `initialHtml`, `HtmlCacheService.applyThemePrelude()` is applied at **load time** (not save time) based on the webview's current theme. For dark themes it prepends this to the cached HTML's `<head>`:

```html
<meta name="color-scheme" content="dark">
<style id="__ws_cache_prelude">
html,body{background:#111 !important;color-scheme:dark}
</style>
```

This eliminates the white-frame flash while the cached HTML's stylesheets and user scripts re-run on the live load. The prelude is keyed on the live `WebViewModel.currentTheme` plus platform brightness (for `WebViewTheme.system`), so a theme switch takes effect on the next cache load without cache invalidation. The helper is idempotent — duplicate prelude insertion is detected via the `__ws_cache_prelude` id.

---

## Files

### Modified
- `lib/services/webview.dart` — `WebViewTheme` enum, theme injection
- `lib/web_view_model.dart` — theme state, webview recreation with `UniqueKey`
- `lib/main.dart` — theme toggle
