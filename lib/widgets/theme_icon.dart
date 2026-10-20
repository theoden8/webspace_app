import 'package:flutter/material.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// The icon a theme goes by, wherever one is picked or shown.
extension WebViewThemeIcon on WebViewTheme {
  IconData get icon => switch (this) {
        WebViewTheme.light => Icons.wb_sunny,
        WebViewTheme.dark => Icons.nights_stay,
        WebViewTheme.system => Icons.brightness_auto,
      };
}

/// Following the app has an icon of its own, so it does not read as the
/// light or dark choice it currently resolves to.
extension ScopedThemeIcon on Scoped<WebViewTheme> {
  IconData get icon => switch (this) {
        FollowApp() => Icons.settings_brightness,
        Own(:final value) => value.icon,
      };
}
