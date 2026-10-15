import 'package:flutter/material.dart';

/// The icon a theme mode goes by, wherever one is picked or shown.
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
      ThemeMode.light => Icons.wb_sunny,
      ThemeMode.dark => Icons.nights_stay,
      ThemeMode.system => Icons.brightness_auto,
    };
