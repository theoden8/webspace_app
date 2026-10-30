import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/theme/design_tokens.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/icon_choice_chips.dart';
import 'package:webspace/widgets/theme_icon.dart';

/// How the app itself looks: UI language, theme mode and accent colour, and
/// in Alternative design how large the launcher's icons are.
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
    setState(() => _settings = newSettings);
    widget.onSettingsChanged(newSettings);
  }

  /// A language override's name; the empty tag follows the system.
  Localized _languageName(AppLocalizations loc, {required String tag}) =>
      tag.isEmpty
          ? loc.appSettingsLanguageSystem
          : Localized.verbatim(languageLabelForTag(tag));

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
              for (final tag in ['', ...tags])
                RadioListTile<String>(
                  value: tag,
                  groupValue: current,
                  title: Text(_languageName(loc, tag: tag)),
                  onChanged: (v) => Navigator.pop(ctx, v ?? ''),
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
            subtitle: _languageName(loc, tag: AppPref.appLocaleOverride.value),
            control: Opens(() => guardedOpen(_pickAppLanguage)),
          ),
          SettingsSection(loc.appSettingsTheme),
          IconChoiceChips<ThemeMode>(
            values: const [ThemeMode.light, ThemeMode.dark, ThemeMode.system],
            face: (mode) => (
              icon: mode.webViewTheme.icon,
              label: mode.webViewTheme.label(loc),
            ),
            value: _settings.themeMode,
            onChanged: (mode) =>
                _updateSettings(_settings.copyWith(themeMode: mode)),
          ),
          SettingsSection(loc.appSettingsAccentColor),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final color in AccentColor.values)
                  _buildAccentColorSwatch(color),
              ],
            ),
          ),
          if (ExperimentalFeaturesService.instance.isEnabled(
            ExperimentalFeature.folderLibrary,
          )) ...[
            SettingsSection(loc.appSettingsExperimentalFolderLibrary),
            PrefSlider(
              AppPref.libraryIconSize,
              title: loc.appSettingsLibraryIconSize,
              hint: loc.appSettingsLibraryIconSizeHint,
              min: LibraryStyle.iconSizeMin,
              max: LibraryStyle.iconSizeMax,
              step: LibraryStyle.iconSizeStep,
              label: (size) => '$size%',
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildAccentColorSwatch(AccentColor color) {
    final isSelected = _settings.accentColor == color;
    final displayColor = color.color;
    final label = color.name[0].toUpperCase() + color.name.substring(1);

    return GestureDetector(
      onTap: () => _updateSettings(_settings.copyWith(accentColor: color)),
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
