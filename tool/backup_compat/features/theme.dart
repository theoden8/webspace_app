import 'package:flutter/material.dart' show ThemeMode;
import 'package:webspace/theme/app_theme.dart' show AccentColor, AppThemeSettings;

int shimThemeIndex(String themeMode, {required String accentColor}) =>
    AppThemeSettings(
      themeMode: ThemeMode.values.byName(themeMode),
      accentColor: AccentColor.values.byName(accentColor),
    ).toStorageIndex();
