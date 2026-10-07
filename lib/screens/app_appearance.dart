import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/theme/accent_theme.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';

const Map<AccentColor, Color> _accentColors = {
  AccentColor.blue: accentBlue,
  AccentColor.green: accentGreen,
  AccentColor.purple: accentPurple,
  AccentColor.orange: accentOrange,
  AccentColor.red: accentRed,
  AccentColor.pink: accentPink,
  AccentColor.teal: accentTeal,
  AccentColor.yellow: accentYellow,
};

/// The label a theme mode goes by, on its chip and in the App Settings row.
String themeModeLabel(AppLocalizations loc, ThemeMode mode) => switch (mode) {
      ThemeMode.light => loc.appSettingsThemeLight,
      ThemeMode.dark => loc.appSettingsThemeDark,
      ThemeMode.system => loc.appSettingsThemeSystem,
    };

/// How the app itself looks: UI language, theme mode and accent colour.
class AppAppearanceScreen extends StatefulWidget {
  const AppAppearanceScreen({
    super.key,
    required this.settings,
    required this.onSettingsChanged,
  });

  final AppThemeSettings settings;
  final ValueChanged<AppThemeSettings> onSettingsChanged;

  @override
  State<AppAppearanceScreen> createState() => _AppAppearanceScreenState();
}

class _AppAppearanceScreenState extends State<AppAppearanceScreen>
    with SettingsOpenGuard, RebuildOnAppPref {
  late AppThemeSettings _settings = widget.settings;

  void _updateSettings(AppThemeSettings newSettings) {
    setState(() {
      _settings = newSettings;
    });
    widget.onSettingsChanged(newSettings);
  }

  Future<void> _pickAppLanguage() async {
    final loc = AppLocalizations.of(context);
    final tags = AppLocalizations.supportedLocales
        .map(tagForLocale)
        .toSet()
        .toList()
      ..sort((a, b) => languageLabelForTag(a)
          .toLowerCase()
          .compareTo(languageLabelForTag(b).toLowerCase()));
    final current = AppPref.appLocaleOverride.value;
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.appSettingsLanguageTitle),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              RadioListTile<String>(
                value: '',
                groupValue: current,
                title: Text(loc.appSettingsLanguageSystem),
                onChanged: (v) => Navigator.pop(ctx, v ?? ''),
              ),
              for (final tag in tags)
                RadioListTile<String>(
                  value: tag,
                  groupValue: current,
                  title: Text(languageLabelForTag(tag)),
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null) await AppPref.appLocaleOverride.set(selected);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsAppearance)),
      body: ListView(
        children: [
          SettingTile(
            leading: const Icon(Icons.language),
            title: loc.appSettingsLanguageTitle,
            hint: null,
            subtitle: AppPref.appLocaleOverride.value.isEmpty
                ? loc.appSettingsLanguageSystem
                : languageLabelForTag(AppPref.appLocaleOverride.value),
            control: Opens(() => guardedOpen(_pickAppLanguage)),
          ),
          SettingsSection(loc.appSettingsTheme),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _buildThemeModeRow(),
          ),
          SettingsSection(loc.appSettingsAccentColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _buildAccentColorGrid(),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildThemeModeRow() => Row(
        spacing: 8,
        children: [
          for (final mode in const [
            ThemeMode.light,
            ThemeMode.dark,
            ThemeMode.system,
          ])
            Expanded(child: _buildThemeModeChip(mode)),
        ],
      );

  Widget _buildThemeModeChip(ThemeMode mode) {
    final label = themeModeLabel(AppLocalizations.of(context), mode);
    final icon = switch (mode) {
      ThemeMode.light => Icons.wb_sunny,
      ThemeMode.dark => Icons.nights_stay,
      ThemeMode.system => Icons.brightness_auto,
    };
    final isSelected = _settings.themeMode == mode;
    final accentColor = Theme.of(context).colorScheme.secondary;

    return GestureDetector(
      onTap: () {
        _updateSettings(_settings.copyWith(themeMode: mode));
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? accentColor.withOpacity(0.15) : Colors.transparent,
          border: Border.all(
            color: isSelected ? accentColor : Colors.grey.shade400,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 24,
              color: isSelected ? accentColor : null,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? accentColor : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccentColorGrid() {
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: AccentColor.values.map((color) {
        return _buildAccentColorSwatch(color);
      }).toList(),
    );
  }

  Widget _buildAccentColorSwatch(AccentColor color) {
    final isSelected = _settings.accentColor == color;
    final displayColor = _accentColors[color]!;
    final label = color.name[0].toUpperCase() + color.name.substring(1);

    return GestureDetector(
      onTap: () {
        _updateSettings(_settings.copyWith(accentColor: color));
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: displayColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 3,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: displayColor.withOpacity(0.6),
                        blurRadius: 8,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: isSelected
                ? const Icon(
                    Icons.check,
                    color: Colors.white,
                    size: 24,
                  )
                : null,
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
