# Webview Theme Preference Feature

## Overview

The app now supports suggesting/applying the app's theme (light/dark mode) to webviews! When you toggle the app's theme, all webviews will be instructed to use that theme preference.

## How It Works

### 1. Theme Detection
- The app tracks its current theme mode (`light`, `dark`, or `system`)
- When the theme is toggled, the app converts it to `WebViewTheme` enum

### 2. Theme Application
Theme is applied to webviews via JavaScript injection that:
- Sets the `<meta name="color-scheme">` tag in the page's `<head>`
- Sets `color-scheme` CSS property on `document.documentElement`

This tells websites that support dark mode to switch their appearance.

### 3. When Theme is Applied
- **On webview creation**: When controller is initialized
- **On page navigation**: After each page load (reapplies in case site overrides)
- **On theme toggle**: Immediately applied to all existing webviews
- **On app startup**: Applied to all restored webviews

## Technical Implementation

### Platform Abstraction
```dart
// lib/platform/unified_webview.dart
enum WebViewTheme {
  light,
  dark,
  system,
}

// lib/platform/webview_factory.dart
abstract class UnifiedWebViewController {
  ...
  Future<void> setThemePreference(WebViewTheme theme);
}
```

### JavaScript Injection
Both `flutter_inappwebview` (Android) and `webview_cef` (Linux) use the same approach:

```javascript
(function() {
  // Set color-scheme meta tag
  let metaTag = document.querySelector('meta[name="color-scheme"]');
  if (!metaTag) {
    metaTag = document.createElement('meta');
    metaTag.name = 'color-scheme';
    document.head.appendChild(metaTag);
  }
  metaTag.content = 'dark'; // or 'light'
  
  // Set CSS property
  document.documentElement.style.colorScheme = 'dark';
})();
```

### WebViewModel Integration
```dart
class WebViewModel {
  WebViewTheme _currentTheme = WebViewTheme.light;
  
  Future<void> setTheme(WebViewTheme theme) async {
    _currentTheme = theme;
    if (controller != null) {
      await controller!.setThemePreference(theme);
    }
  }
}
```

## Browser Compatibility

### Websites That Support This
✅ **Modern web apps** with dark mode support (GitHub, VS Code Web, etc.)  
✅ **Sites using CSS `prefers-color-scheme` media queries**  
✅ **Progressive web apps** with proper color-scheme meta tags  

### Websites That Don't Support This
❌ **Legacy sites** without dark mode  
❌ **Sites with forced light theme** in CSS  
❌ **Sites that ignore color-scheme preferences**  

## User Experience

1. **Toggle app theme** using the sun/moon icon in the app bar
2. **All webviews update** automatically to match the theme
3. **New pages respect** the theme when they load
4. **Preference persists** across app restarts

## Example

```dart
// When user toggles theme
onPressed: () async {
  setState(() {
    _themeMode = ThemeMode.dark; // or light
  });
  
  // Apply to all webviews
  final webViewTheme = _themeModeToWebViewTheme(_themeMode);
  for (var webViewModel in _webViewModels) {
    await webViewModel.setTheme(webViewTheme);
  }
},
```

## Limitations

- **No forced dark mode**: This is a *suggestion* to websites, not forced rendering
- **Site-dependent**: Websites must implement their own dark mode
- **JavaScript required**: Theme application requires JavaScript enabled
- **Best effort**: Some sites may not respond to the preference

## Future Improvements

- Add per-site theme override (some users may want specific sites in light/dark)
- Implement forced dark mode rendering (requires platform-specific APIs)
- Add theme preference to settings screen
- Support custom color schemes beyond light/dark
