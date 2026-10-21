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

The app SHALL suggest a theme (light, dark, or system) to every webview that
runs as a site: the site's own theme when it has one, the app's theme mode
otherwise (HINTS-006).

#### Scenario: Apply dark theme hint

**Given** the app is set to dark mode
**And** the site follows the app's theme
**When** a webview is created
**Then** the webview receives the dark theme preference via JavaScript injection

---

### Requirement: HINTS-002 - JavaScript Theme Injection

Theme preference SHALL be applied to webviews via JavaScript injection that:
1. Overrides `window.matchMedia` to intercept `prefers-color-scheme` queries
2. Sets the `<meta name="color-scheme">` tag in the page's `<head>`
3. Sets `color-scheme` CSS property on `document.documentElement`
4. Maintains theme change listeners for dynamic updates

The script runs at `AT_DOCUMENT_START`, where the parser has created `<html>`
but not yet `<head>`, and a `color-scheme` meta only counts inside the head. It
SHALL therefore defer the meta insertion to `DOMContentLoaded` rather than
dereference `document.head`: an uncaught throw there drops the rest of the
script, which is the theme-change listener replay.

#### Scenario: Inject dark mode preference

**Given** the app is in dark mode
**When** a page loads
**Then** JavaScript sets `<meta name="color-scheme" content="dark">`
**And** sets `document.documentElement.style.colorScheme = 'dark'`
**And** `window.matchMedia('(prefers-color-scheme: dark)')` returns `{ matches: true }`

#### Scenario: Injected before the document has a head

Regression: `document.head.appendChild` threw "Cannot read properties of null"
on every page load, so the meta tag and the listener replay never ran.

**Given** the shim runs at document start with `document.head` still null
**Then** nothing is thrown
**And** `document.documentElement.style.colorScheme` is set immediately
**And** `<meta name="color-scheme">` is added once the head exists

---

### Requirement: HINTS-003 - Theme Application Timing

The theme hint SHALL be applied:
1. On webview creation, as a document-start user script, so the first
   document already has it: the site's webview, a nested screen its links
   open, and a popup either spawns
2. On page navigation (theme reapplied after each page load)
3. On a change to the app's theme mode (immediately to every existing webview
   whose site follows the app)
4. On app startup (to all restored webviews)
5. On a change to the site's own theme (its webview is rebuilt on save)

#### Scenario: Apply an app theme change

**Given** multiple webviews are open
**And** one site is set to Light and the others follow the app
**When** the user changes the app's theme from light to dark in App Settings
**Then** the webviews of the sites that follow the app immediately receive the
dark theme preference
**And** the site set to Light keeps the light preference

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

### Requirement: HINTS-006 - Per-Site Theme

Each site SHALL have a Theme setting with the values App default (the
default), Light, Dark and System: one settings row, its title on the left and
the four values as icon segments on the right, each naming its value in a
tooltip, the same control the tab strip's rows in App Settings > Behaviour
use. App default follows the app's theme mode and has an icon of its own; the
row's subtitle names the theme it currently gives, such as App default (Dark).
The others are the site's own. Every webview that runs as the site, including
a nested screen or a popup it opens, SHALL receive the site's own value when
it has one and the app's otherwise.

The setting is configuration: it is stored with the site, carried by a backup
and by a shared site QR, and a stored value this build does not name follows
the app.

The app SHALL NOT offer a theme toggle in an app bar (the main page or the
add-site screen). The app's own theme mode is set in App Settings >
Appearance.

#### Scenario: A new site follows the app

**Given** the app is set to dark mode
**When** the user adds a site
**Then** the site's Theme reads App default (Dark)
**And** its pages receive the dark preference
**When** the user switches the app to light mode
**Then** its pages receive the light preference

#### Scenario: A site with its own theme

**Given** the app is set to dark mode
**And** a site's Theme is Light
**When** the site's page loads
**Then** it receives the light preference
**And** a nested screen opened from one of its links receives the light
preference

#### Scenario: No theme toggle in the app bar

**Given** a site is on screen
**Then** the app bar offers no theme action

---

## Data Model

```dart
// lib/settings/web_view_theme.dart
enum WebViewTheme {
  light,
  dark,
  system,
}

// WebViewModel: the site's own theme, null following the app's, and what a
// webview of the site applies (also SitePosture.page.theme).
WebViewTheme? theme;
WebViewTheme get effectiveTheme;

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

### File Import Theme Prelude

When a file import's stored HTML is rendered via `initialHtml`, `HtmlImportStorage.applyThemePrelude()` is applied at **load time** (not save time) based on the webview's current theme. For dark themes it prepends this to the import's `<head>`:

```html
<meta name="color-scheme" content="dark">
<style id="__ws_cache_prelude">
html,body{background:#111 !important;color-scheme:dark}
</style>
```

This eliminates the white-frame flash while the import's stylesheets and user scripts run. The prelude is keyed on the live `WebViewModel.effectiveTheme` plus platform brightness (for `WebViewTheme.system`), so a theme switch takes effect on the next build without touching the stored bytes. A URL site's first page comes from the network or the engine's cache and gets no prelude. The helper is idempotent — duplicate prelude insertion is detected via the `__ws_cache_prelude` id.

---

## Files

### Modified
- `lib/settings/web_view_theme.dart` — `WebViewTheme` enum
- `lib/services/page_scripts.dart` — the theme shim at webview creation
- `lib/services/webview_controller.dart` — `setThemePreference`, which replaces it
- `lib/web_view_model.dart` — the per-site theme and the one it resolves to
- `lib/screens/settings.dart` — the per-site Theme row
- `lib/widgets/icon_choice_chips.dart`, `lib/widgets/theme_icon.dart` — the
  icon picker both theme rows use, and each choice's icon
- `lib/screens/app_appearance.dart` — the app's theme mode
