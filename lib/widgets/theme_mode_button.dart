import 'package:flutter/material.dart';

/// The icon a theme mode goes by, wherever one is picked or shown.
IconData themeModeIcon(ThemeMode mode) => switch (mode) {
      ThemeMode.light => Icons.wb_sunny,
      ThemeMode.dark => Icons.nights_stay,
      ThemeMode.system => Icons.brightness_auto,
    };

/// Light, then dark, then the system's: the order a tap on
/// [ThemeModeButton] steps through.
ThemeMode nextThemeMode(ThemeMode mode) => switch (mode) {
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
      ThemeMode.system => ThemeMode.light,
    };

/// An app bar action showing [mode] that steps to the next one on a tap.
class ThemeModeButton extends StatelessWidget {
  const ThemeModeButton({
    super.key,
    required this.mode,
    required this.tooltip,
    required this.onChanged,
  });

  final ThemeMode mode;
  final String tooltip;
  final ValueChanged<ThemeMode> onChanged;

  @override
  Widget build(BuildContext context) => IconButton(
        icon: Icon(themeModeIcon(mode)),
        tooltip: tooltip,
        onPressed: () => onChanged(nextThemeMode(mode)),
      );
}
