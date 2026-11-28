import 'dart:ui' show Brightness, Color;

/// The color scheme a site's pages are told to prefer (HINTS-001). Its names
/// are what the theme shim reads and what a site's JSON stores.
enum WebViewTheme {
  light,
  dark,
  system;

  /// The scheme a page is told while the platform's brightness is
  /// [platform]: `system` is the platform's.
  Brightness under(Brightness platform) => switch (this) {
        WebViewTheme.light => Brightness.light,
        WebViewTheme.dark => Brightness.dark,
        WebViewTheme.system => platform,
      };
}

/// The app's background in [brightness]: under its screens, and under a
/// webview whose page has not painted yet (A11Y-008).
Color appBackground(Brightness brightness) => switch (brightness) {
      Brightness.light => const Color(0xFFFFFFFF),
      Brightness.dark => const Color(0xFF000000),
    };
