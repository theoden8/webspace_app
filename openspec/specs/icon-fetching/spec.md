# Icon Fetching Specification

## Purpose

Comprehensive icon fetching system for the Webspace app that provides high-quality favicons through multiple sources, progressive loading, and intelligent selection.

## Status

- **Date**: 2026-01-25
- **Status**: Completed

---

## Requirements

### Requirement: ICON-001 - Progressive Icon Loading

Icons SHALL load progressively instead of waiting for all sources to complete.

#### Scenario: Show icon quickly and upgrade

**Given** a user adds a site
**When** the icon is being fetched
**Then** a low-resolution icon appears within 1-2 seconds (DuckDuckGo ~64px)
**And** the icon upgrades to higher resolution as better versions are found

---

### Requirement: ICON-002 - Multiple Icon Sources

The system SHALL fetch icons from multiple sources in parallel:

1. DuckDuckGo (fast, ~64px)
2. Google Favicons (128px, 256px)
3. HTML parsing (native icons from page)
4. /favicon.ico fallback

#### Scenario: Select best available icon

**Given** DuckDuckGo returns a 64px icon
**And** Google returns a 256px icon
**And** HTML parsing finds a 1000px colored SVG
**When** selection is made
**Then** the SVG is chosen (highest quality score: 1000)

---

### Requirement: ICON-003 - Quality Scoring System

Icons SHALL be scored based on quality:

| Score | Type |
|-------|------|
| 1000 | Colored SVG icons (scale-invariant) |
| 256 | Google 256px (colored, high-res) |
| 128 | Google 128px, HTML high-res icons |
| 64 | DuckDuckGo (colored) |
| 50 | Monochrome SVG icons |
| 32 | /favicon.ico fallback |
| 16 | HTML unknown size icons |

#### Scenario: Prioritize colored SVG

**Given** a site has both a PNG favicon and a colored SVG logo
**When** icons are fetched
**Then** the colored SVG is selected (score 1000 > PNG scores)

---

### Requirement: ICON-004 - SVG Color Detection

The system SHALL detect whether SVG icons are colored or monochrome.

#### Scenario: Detect colored SVG

**Given** an SVG contains `fill="#2185d0"`
**When** color detection runs
**Then** the SVG is marked as colored (quality 1000)

#### Scenario: Detect monochrome SVG

**Given** an SVG contains only `fill="#000"` and `fill="#fff"`
**When** color detection runs
**Then** the SVG is marked as monochrome (quality 50)

#### Scenario: Reject CSS visibility-switching SVG

**Given** an SVG contains a `<style>` block with `display: none` (e.g. theme-aware
icons that toggle between `#light-icon` and `#dark-icon` groups via CSS or
`@media (prefers-color-scheme: dark)`)
**When** color detection runs
**Then** the SVG is treated as low quality (not colored)
**And** a bitmap icon is preferred instead

This guards against flutter_svg's limited CSS support: `display: none` from
`<style>` blocks is not honored, so every `<g>` group renders and hidden
background rects can obscure the visible icon. duck.ai's favicon.svg is a
concrete example — without this guard, the icon appears as a near-empty
white rounded square.

---

### Requirement: ICON-005 - SVG Dark Mode Support

SVG icons with CSS media queries SHALL render correctly based on app theme
when flutter_svg supports the CSS features used.

#### Scenario: Render SVG in dark mode

**Given** an SVG contains `@media (prefers-color-scheme: dark)`
**And** the app is in dark mode
**When** the SVG is rendered
**Then** the dark mode styles are applied

#### Scenario: Reject SVGs relying on CSS visibility toggles

**Given** an SVG uses `<style>` with `display: none` to hide the inactive
theme variant (rather than conditional styling of a single rendered tree)
**When** icon selection runs
**Then** the SVG is rejected by ICON-004's color detection
**And** a bitmap icon from the same site is selected instead

This avoids rendering all theme variants simultaneously, which flutter_svg
would otherwise do.

---

### Requirement: ICON-006 - Smart Public Service Filtering

Google and DuckDuckGo icon services SHALL be skipped for:
- http:// sites (non-HTTPS)
- IPv4 addresses (e.g., 192.168.1.1)
- IPv6 addresses (e.g., [::1])
- localhost

#### Scenario: Skip public services for local server

**Given** a user adds "http://192.168.1.100:8080"
**When** icons are fetched
**Then** DuckDuckGo and Google services are not queried
**And** only direct favicon fetch and HTML parsing are used

---

### Requirement: ICON-007 - Domain Substitution

The system SHALL support domain substitution for better icon quality.

```dart
const Map<String, String> _domainSubstitutions = {
  'gmail.com': 'mail.google.com',
};
```

#### Scenario: Substitute gmail.com domain

**Given** a user adds gmail.com
**When** icons are fetched
**Then** icons are fetched from mail.google.com instead

---

### Requirement: ICON-008 - Icon Caching

Fetched icons SHALL be cached to avoid redundant network requests.

#### Scenario: Return cached icon

**Given** an icon was fetched for example.com 5 minutes ago
**When** the icon is requested again
**Then** the cached result is returned immediately

#### Scenario: Page refresh does not invalidate icon cache

**Given** a site has a cached favicon
**When** the user refreshes the page from the nav bar
**Then** only the page is reloaded
**And** the cached favicon is NOT re-fetched

#### Scenario: Drawer refresh invalidates icon cache

**Given** a site has a cached favicon
**When** the user taps the refresh button in the drawer site list
**Then** the favicon cache is invalidated and the icon is re-fetched
**And** the page title is also refreshed

---

## Performance

- **Before**: Users waited 10-15 seconds seeing a spinner
- **After**: Icons appear within 1-2 seconds, then upgrade as better versions load

---

## Files

### Created
- `lib/services/icon_service.dart` - Icon fetching service

### Modified
- `lib/screens/add_site.dart` - UnifiedFaviconImage widget, SVG support
- `lib/screens/webspace_detail.dart` - Icons in site selection
- `pubspec.yaml` - Added `flutter_svg: ^2.0.10+1`
