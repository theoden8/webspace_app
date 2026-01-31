import 'package:flutter/material.dart';

import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;

class AppSettingsScreen extends StatefulWidget {
  final AppThemeSettings currentSettings;
  final Function(AppThemeSettings) onSettingsChanged;
  final VoidCallback onExportSettings;
  final VoidCallback onImportSettings;

  const AppSettingsScreen({
    super.key,
    required this.currentSettings,
    required this.onSettingsChanged,
    required this.onExportSettings,
    required this.onImportSettings,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late AppThemeSettings _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.currentSettings;
  }

  void _updateSettings(AppThemeSettings newSettings) {
    setState(() {
      _settings = newSettings;
    });
    widget.onSettingsChanged(newSettings);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Settings'),
      ),
      body: ListView(
        children: [
          // Theme Mode Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Theme',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          _buildThemeModeOption(
            ThemeMode.light,
            'Light',
            Icons.wb_sunny,
          ),
          _buildThemeModeOption(
            ThemeMode.dark,
            'Dark',
            Icons.nights_stay,
          ),
          _buildThemeModeOption(
            ThemeMode.system,
            'System',
            Icons.brightness_auto,
          ),
          
          const Divider(height: 32),
          
          // Accent Color Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Accent Color',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          _buildAccentColorOption(
            AccentColor.blue,
            'Blue',
            const Color(0xFF6B8DD6),
          ),
          _buildAccentColorOption(
            AccentColor.green,
            'Green',
            const Color(0xFF7be592),
          ),
          
          const Divider(height: 32),

          // Data Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Data',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload),
            title: const Text('Export Settings'),
            subtitle: const Text('Save sites and webspaces to a file'),
            onTap: () {
              Navigator.pop(context);
              widget.onExportSettings();
            },
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: const Text('Import Settings'),
            subtitle: const Text('Restore from a backup file'),
            onTap: () {
              Navigator.pop(context);
              widget.onImportSettings();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildThemeModeOption(ThemeMode mode, String label, IconData icon) {
    final isSelected = _settings.themeMode == mode;
    return RadioListTile<ThemeMode>(
      value: mode,
      groupValue: _settings.themeMode,
      onChanged: (value) {
        if (value != null) {
          _updateSettings(_settings.copyWith(themeMode: value));
        }
      },
      title: Row(
        children: [
          Icon(
            icon,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
      selected: isSelected,
      activeColor: Theme.of(context).colorScheme.secondary,
    );
  }

  Widget _buildAccentColorOption(AccentColor color, String label, Color displayColor) {
    final isSelected = _settings.accentColor == color;
    return RadioListTile<AccentColor>(
      value: color,
      groupValue: _settings.accentColor,
      onChanged: (value) {
        if (value != null) {
          _updateSettings(_settings.copyWith(accentColor: value));
        }
      },
      title: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: displayColor,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? displayColor : Colors.grey.shade400,
                width: 2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(label),
        ],
      ),
      selected: isSelected,
      activeColor: Theme.of(context).colorScheme.secondary,
    );
  }
}
