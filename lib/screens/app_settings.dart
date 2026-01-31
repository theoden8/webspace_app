import 'package:flutter/material.dart';

import 'package:webspace/main.dart' show AppTheme;

class AppSettingsScreen extends StatefulWidget {
  final AppTheme currentTheme;
  final Function(AppTheme) onThemeChanged;
  final VoidCallback onExportSettings;
  final VoidCallback onImportSettings;

  const AppSettingsScreen({
    super.key,
    required this.currentTheme,
    required this.onThemeChanged,
    required this.onExportSettings,
    required this.onImportSettings,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen> {
  late AppTheme _selectedTheme;

  @override
  void initState() {
    super.initState();
    _selectedTheme = widget.currentTheme;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('App Settings'),
      ),
      body: ListView(
        children: [
          // Theme Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Theme',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          _buildThemeOption(
            AppTheme.lightBlue,
            'Light Blue',
            Icons.wb_sunny,
            Colors.blue,
          ),
          _buildThemeOption(
            AppTheme.darkBlue,
            'Dark Blue',
            Icons.nights_stay,
            Colors.blue,
          ),
          _buildThemeOption(
            AppTheme.lightGreen,
            'Light Green',
            Icons.wb_sunny,
            Colors.green,
          ),
          _buildThemeOption(
            AppTheme.darkGreen,
            'Dark Green',
            Icons.nights_stay,
            Colors.green,
          ),
          _buildThemeOption(
            AppTheme.system,
            'System',
            Icons.brightness_auto,
            null,
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

  Widget _buildThemeOption(AppTheme theme, String label, IconData icon, Color? accentColor) {
    final isSelected = _selectedTheme == theme;
    return RadioListTile<AppTheme>(
      value: theme,
      groupValue: _selectedTheme,
      onChanged: (value) {
        if (value != null) {
          setState(() {
            _selectedTheme = value;
          });
          widget.onThemeChanged(value);
        }
      },
      title: Row(
        children: [
          Icon(
            icon,
            color: accentColor,
            size: 20,
          ),
          const SizedBox(width: 12),
          Text(label),
          if (accentColor != null) ...[
            const SizedBox(width: 8),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: accentColor,
                shape: BoxShape.circle,
              ),
            ),
          ],
        ],
      ),
      selected: isSelected,
      activeColor: Theme.of(context).colorScheme.secondary,
    );
  }
}
