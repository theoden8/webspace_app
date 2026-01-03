# Test Fixtures

This directory contains HTML test files for automated testing of WebSpace features.

## Favicon Tests

### `site_with_favicon.html`
- **Feature**: Favicon detection from `<link rel="icon">`
- **Expected**: Should find and use `/static/favicon.ico`

### `site_without_favicon.html`
- **Feature**: Fallback behavior when no favicon links exist
- **Expected**: Should try `/favicon.ico`, then show default icon on failure

### `site_with_relative_favicon.html`
- **Feature**: Relative path resolution (`assets/icons/favicon.png`)
- **Expected**: Should resolve to `http://localhost:PORT/assets/icons/favicon.png`

### `site_with_absolute_favicon.html`
- **Feature**: Absolute path resolution (`/favicon.ico`)
- **Expected**: Should resolve to `http://localhost:PORT/favicon.ico`

### `site_with_cdn_favicon.html`
- **Feature**: Full URL favicon (`https://cdn.example.com/icons/favicon.png`)
- **Expected**: Should use URL as-is

### `site_with_protocol_relative_favicon.html`
- **Feature**: Protocol-relative URLs (`//static.example.com/favicon.ico`)
- **Expected**: Should prepend current protocol (`http:` or `https:`)

## Title Extraction Tests

### `site_title_extraction.html`
- **Feature**: Page title extraction from `<title>` tag
- **Expected**: Site name should auto-update to "Test Page Title - WebSpace App"

### `site_no_title.html`
- **Feature**: Missing `<title>` tag
- **Expected**: Should fallback to domain name

### `site_empty_title.html`
- **Feature**: Empty `<title>` tag
- **Expected**: Should fallback to domain name

## Theme Tests

### `site_theme_support.html`
- **Feature**: Dark/light theme detection and switching
- **Expected**: Should respond to `prefers-color-scheme` changes

### `site_no_theme_support.html`
- **Feature**: Sites without theme support
- **Expected**: JavaScript injection should add `color-scheme` meta tag

## General Test Page

### `test_page.html`
- **Feature**: Comprehensive test page with multiple features
- **Expected**: Tests title, favicon, theme, and basic HTML structure

## Usage in Tests

```dart
import 'dart:io';

void main() {
  test('favicon detection', () {
    final html = File('test/fixtures/site_with_favicon.html').readAsStringSync();
    // Parse and test favicon detection
  });
}
```

## Port Assignment for Testing

When serving these files locally:
- Use random available ports to avoid conflicts
- Pass port to tests via environment or parameters
- Clean up server after tests complete
