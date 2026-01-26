# Webview Theme Preference Specification

## Overview

The app supports suggesting/applying the app's theme (light/dark mode) to webviews. When you toggle the app's theme, all webviews will be instructed to use that theme preference.

## Status

- **Status**: Completed

---

## Requirements

### Requirement: THEME-001 - Theme Detection

The app SHALL track its current theme mode (light, dark, or system).

#### Scenario: Detect current theme

**Given** the app is set to dark mode
**When** a webview is created
**Then** the webview receives the dark theme preference

---

### Requirement: THEME-002 - JavaScript Theme Injection

Theme SHALL be applied to webviews via JavaScript injection that:
1. Sets the `<meta name="color-scheme">` tag in the page's `<head>`
2. Sets `color-scheme` CSS property on `document.documentElement`

#### Scenario: Inject dark mode preference

**Given** the app is in dark mode
**When** a page loads
**Then** JavaScript sets `<meta name="color-scheme" content="dark">`
**And** sets `document.documentElement.style.colorScheme = 'dark'`

---

### Requirement: THEME-003 - Theme Application Timing

Theme SHALL be applied:
1. On webview creation (when controller is initialized)
2. On page navigation (after each page load)
3. On theme toggle (immediately to all existing webviews)
4. On app startup (to all restored webviews)

#### Scenario: Apply theme on toggle

**Given** multiple webviews are open
**When** the user toggles from light to dark mode
**Then** all webviews immediately receive the dark theme preference

---

### Requirement: THEME-004 - Theme Persistence

Theme preference SHALL persist across app restarts.

#### Scenario: Restore theme on restart

**Given** the user set dark mode
**When** the app is closed and reopened
**Then** dark mode is still active
**And** all webviews receive dark theme preference

---

### Requirement: THEME-005 - Cross-Platform Consistency

Theme injection SHALL work on all supported platforms.

#### Scenario: Theme works on Android and Linux

**Given** the same webview content
**When** dark mode is applied on Android
**And** dark mode is applied on Linux
**Then** both platforms inject the same theme preference

---

## Data Model

```dart
enum WebViewTheme {
  light,
  dark,
  system,
}

abstract class UnifiedWebViewController {
  Future<void> setThemePreference(WebViewTheme theme);
}
```

---

## Browser Compatibility

### Websites That Support This
- Modern web apps with dark mode support (GitHub, VS Code Web, etc.)
- Sites using CSS `prefers-color-scheme` media queries
- Progressive web apps with proper color-scheme meta tags

### Websites That Don't Support This
- Legacy sites without dark mode
- Sites with forced light theme in CSS
- Sites that ignore color-scheme preferences

---

## Limitations

- **No forced dark mode**: This is a *suggestion* to websites, not forced rendering
- **Site-dependent**: Websites must implement their own dark mode
- **JavaScript required**: Theme application requires JavaScript enabled
- **Best effort**: Some sites may not respond to the preference

---

## Files

### Modified
- `lib/platform/unified_webview.dart` - WebViewTheme enum
- `lib/platform/webview_factory.dart` - setThemePreference implementation
- `lib/web_view_model.dart` - Theme state tracking
- `lib/main.dart` - Theme toggle and propagation
