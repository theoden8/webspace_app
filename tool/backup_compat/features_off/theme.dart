import 'package:flutter/material.dart' show ThemeMode;

/// Before accent colours the export wrote `ThemeMode.index` as is.
int shimThemeIndex(String themeMode, String accentColor) =>
    ThemeMode.values.byName(themeMode).index;
