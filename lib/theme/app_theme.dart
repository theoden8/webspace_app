import 'package:flutter/material.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/settings/web_view_theme.dart';

/// The app's theme. It names no font family or fallback: a flag takes the
/// colour emoji font through `flagText`. A switch, checkbox or radio that is
/// on draws `accentIndicator`, which holds 3:1 where `primary` does not
/// (A11Y-010); a disabled one keeps Material's colours.
ThemeData buildAppTheme(Color accent,
    {required Brightness brightness,
    ThemeContrast contrast = ThemeContrast.standard}) {
  final scheme =
      buildAccentColorScheme(accent, brightness: brightness, contrast: contrast);
  WidgetStateProperty<Color?> whenOn(Color color) =>
      WidgetStateProperty.resolveWith((states) =>
          states.contains(WidgetState.selected) &&
                  !states.contains(WidgetState.disabled)
              ? color
              : null);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: switch (brightness) {
      Brightness.light => const Color(0xFFFFFFFF),
      Brightness.dark => const Color(0xFF000000),
    },
    switchTheme: SwitchThemeData(
      trackColor: whenOn(scheme.accentIndicator),
      thumbColor: whenOn(scheme.onAccentIndicator),
    ),
    checkboxTheme: CheckboxThemeData(
      fillColor: whenOn(scheme.accentIndicator),
      checkColor: whenOn(scheme.onAccentIndicator),
    ),
    radioTheme: RadioThemeData(fillColor: whenOn(scheme.accentIndicator)),
  );
}

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
