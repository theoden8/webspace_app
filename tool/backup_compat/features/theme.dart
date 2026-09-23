import 'package:flutter/material.dart' show ThemeMode;
import 'package:webspace/main.dart' show AccentColor, AppThemeSettings;

int shimThemeIndex(String themeMode, String accentColor) => AppThemeSettings(
      themeMode: ThemeMode.values.byName(themeMode),
      accentColor: AccentColor.values.byName(accentColor),
    ).toStorageIndex();
