import 'package:flutter/material.dart';
import 'package:webspace/services/webview.dart' show WebViewTheme;
import 'package:webspace/theme/accent_theme.dart';

enum AccentColor {
  blue(accentBlue),
  green(accentGreen),
  purple(accentPurple),
  orange(accentOrange),
  red(accentRed),
  pink(accentPink),
  teal(accentTeal),
  yellow(accentYellow);

  const AccentColor(this.color);

  final Color color;
}

class AppThemeSettings {
  final ThemeMode themeMode;
  final AccentColor accentColor;

  const AppThemeSettings({
    this.themeMode = ThemeMode.system,
    this.accentColor = AccentColor.blue,
  });

  AppThemeSettings copyWith({
    ThemeMode? themeMode,
    AccentColor? accentColor,
  }) {
    return AppThemeSettings(
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
    );
  }

  // For backward compatibility - convert to index for storage
  int toStorageIndex() {
    return themeMode.index * 10 + accentColor.index;
  }

  static AppThemeSettings fromStorageIndex(int index) {
    final themeModeIndex = index ~/ 10;
    final accentColorIndex = index % 10;
    return AppThemeSettings(
      themeMode: themeModeIndex < ThemeMode.values.length
          ? ThemeMode.values[themeModeIndex]
          : ThemeMode.system,
      accentColor: accentColorIndex < AccentColor.values.length
          ? AccentColor.values[accentColorIndex]
          : AccentColor.blue,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is AppThemeSettings &&
        other.themeMode == themeMode &&
        other.accentColor == accentColor;
  }

  @override
  int get hashCode => themeMode.hashCode ^ accentColor.hashCode;
}

/// The theme setting before mode and accent were stored apart; a stored
/// index of one still restores.
enum AppTheme {
  lightBlue(ThemeMode.light, accentColor: AccentColor.blue),
  darkBlue(ThemeMode.dark, accentColor: AccentColor.blue),
  lightGreen(ThemeMode.light, accentColor: AccentColor.green),
  darkGreen(ThemeMode.dark, accentColor: AccentColor.green),
  system(ThemeMode.system, accentColor: AccentColor.blue);

  const AppTheme(this.themeMode, {required this.accentColor});

  final ThemeMode themeMode;
  final AccentColor accentColor;

  AppThemeSettings get settings =>
      AppThemeSettings(themeMode: themeMode, accentColor: accentColor);
}

extension ThemeModeWebView on ThemeMode {
  WebViewTheme get webViewTheme => switch (this) {
        ThemeMode.dark => WebViewTheme.dark,
        ThemeMode.light => WebViewTheme.light,
        ThemeMode.system => WebViewTheme.system,
      };
}
