import 'package:flutter/material.dart';

import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/dns_block_service.dart';

// Accent color definitions for display
const Map<AccentColor, Color> _accentColors = {
  AccentColor.blue: Color(0xFF6B8DD6),
  AccentColor.green: Color(0xFF7be592),
  AccentColor.purple: Color(0xFF9B7BD6),
  AccentColor.orange: Color(0xFFE59B5B),
  AccentColor.red: Color(0xFFD66B6B),
  AccentColor.pink: Color(0xFFD66BA8),
  AccentColor.teal: Color(0xFF5BC4C4),
  AccentColor.yellow: Color(0xFFD6C86B),
};

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

class _AppSettingsScreenState extends State<AppSettingsScreen>
    with SingleTickerProviderStateMixin {
  late AppThemeSettings _settings;
  bool _isDownloadingRules = false;
  DateTime? _rulesLastUpdated;

  // DNS Blocklist state
  bool _isDownloadingBlocklist = false;
  DateTime? _blocklistLastUpdated;
  int _dnsBlockLevel = 0; // Downloaded level
  double _dnsBlockSliderValue = 0; // Ephemeral slider value
  late AnimationController _spinController;

  @override
  void initState() {
    super.initState();
    _settings = widget.currentSettings;
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _loadRulesLastUpdated();
    _loadBlocklistState();
  }

  @override
  void dispose() {
    _spinController.dispose();
    super.dispose();
  }

  Future<void> _loadBlocklistState() async {
    final lastUpdated = await DnsBlockService.instance.getLastUpdated();
    if (mounted) {
      setState(() {
        _dnsBlockLevel = DnsBlockService.instance.level;
        _dnsBlockSliderValue = _dnsBlockLevel.toDouble();
        _blocklistLastUpdated = lastUpdated;
      });
    }
  }

  Future<void> _downloadBlocklist() async {
    final level = _dnsBlockSliderValue.round();

    setState(() {
      _isDownloadingBlocklist = true;
    });
    _spinController.repeat();

    final success = await DnsBlockService.instance.downloadList(level);

    if (mounted) {
      _spinController.stop();
      _spinController.reset();
      setState(() {
        _isDownloadingBlocklist = false;
      });

      if (success) {
        await _loadBlocklistState();
        final domainCount = DnsBlockService.instance.domainCount;
        final message = level == 0
            ? 'DNS blocklist disabled'
            : 'DNS blocklist updated (${_formatNumber(domainCount)} domains)';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download DNS blocklist')),
        );
      }
    }
  }

  String _formatNumber(int n) {
    if (n >= 1000) {
      return '${(n / 1000).toStringAsFixed(n % 1000 == 0 ? 0 : 1)}K';
    }
    return n.toString();
  }

  Future<void> _loadRulesLastUpdated() async {
    final lastUpdated = await ClearUrlService.instance.getLastUpdated();
    if (mounted) {
      setState(() {
        _rulesLastUpdated = lastUpdated;
      });
    }
  }

  Future<void> _downloadRules() async {
    setState(() {
      _isDownloadingRules = true;
    });

    final success = await ClearUrlService.instance.downloadRules();

    if (mounted) {
      setState(() {
        _isDownloadingRules = false;
      });

      if (success) {
        await _loadRulesLastUpdated();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('ClearURLs rules updated')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download ClearURLs rules')),
        );
      }
    }
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _buildThemeModeRow(),
          ),
          
          const SizedBox(height: 24),
          
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: _buildAccentColorGrid(),
          ),
          
          const SizedBox(height: 8),
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

          const Divider(height: 32),

          // Privacy Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Privacy',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('ClearURLs Rules'),
            subtitle: Text(
              _rulesLastUpdated != null
                  ? 'Updated: ${_rulesLastUpdated!.toLocal().toString().split('.')[0]}'
                  : 'Not downloaded',
            ),
            trailing: _isDownloadingRules
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: 'Download rules',
                    onPressed: _downloadRules,
                  ),
          ),

          // DNS Blocklist
          ListTile(
            leading: const Icon(Icons.shield),
            title: const Text('DNS Blocklist'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dnsBlockLevel > 0
                      ? '${dnsBlockLevelNames[_dnsBlockLevel]} - ${_formatNumber(DnsBlockService.instance.domainCount)} domains'
                      : 'Not configured',
                ),
                if (_blocklistLastUpdated != null)
                  Text(
                    'Updated: ${_blocklistLastUpdated!.toLocal().toString().split('.')[0]}',
                    style: const TextStyle(fontSize: 12),
                  ),
              ],
            ),
            trailing: _isDownloadingBlocklist
                ? RotationTransition(
                    turns: _spinController,
                    child: const Icon(Icons.sync),
                  )
                : IconButton(
                    icon: Icon(
                      _dnsBlockSliderValue.round() != _dnsBlockLevel
                          ? Icons.download
                          : Icons.sync,
                    ),
                    tooltip: _dnsBlockSliderValue.round() != _dnsBlockLevel
                        ? 'Download blocklist'
                        : 'Refresh blocklist',
                    onPressed: _downloadBlocklist,
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              children: [
                Slider(
                  value: _dnsBlockSliderValue,
                  min: 0,
                  max: 5,
                  divisions: 5,
                  label: dnsBlockLevelNames[_dnsBlockSliderValue.round()],
                  onChanged: _isDownloadingBlocklist
                      ? null
                      : (value) {
                          setState(() {
                            _dnsBlockSliderValue = value;
                          });
                        },
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (int i = 0; i < dnsBlockLevelNames.length; i++)
                      Text(
                        dnsBlockLevelNames[i],
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: _dnsBlockSliderValue.round() == i
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: _dnsBlockSliderValue.round() == i
                              ? Theme.of(context).colorScheme.secondary
                              : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 32),

          // About Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'About',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('Licenses'),
            subtitle: const Text('Open source licenses'),
            onTap: () {
              showLicensePage(
                context: context,
                applicationName: 'WebSpace',
                applicationVersion: '0.1.0',
                applicationLegalese: '© 2023 Kirill Rodriguez',
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildThemeModeRow() {
    return Row(
      children: [
        Expanded(
          child: _buildThemeModeChip(
            ThemeMode.light,
            'Light',
            Icons.wb_sunny,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildThemeModeChip(
            ThemeMode.dark,
            'Dark',
            Icons.nights_stay,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildThemeModeChip(
            ThemeMode.system,
            'System',
            Icons.brightness_auto,
          ),
        ),
      ],
    );
  }

  Widget _buildThemeModeChip(ThemeMode mode, String label, IconData icon) {
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
          borderRadius: BorderRadius.circular(8),
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
