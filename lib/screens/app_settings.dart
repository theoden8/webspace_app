import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/widgets/hint_button.dart';

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
  final bool showTabStrip;
  final ValueChanged<bool> onShowTabStripChanged;
  final bool showStatsBanner;
  final ValueChanged<bool> onShowStatsBannerChanged;
  final List<UserScriptConfig> globalUserScripts;
  final void Function(List<UserScriptConfig>)? onGlobalUserScriptsChanged;

  const AppSettingsScreen({
    super.key,
    required this.currentSettings,
    required this.onSettingsChanged,
    required this.onExportSettings,
    required this.onImportSettings,
    required this.showTabStrip,
    required this.onShowTabStripChanged,
    required this.showStatsBanner,
    required this.onShowStatsBannerChanged,
    this.globalUserScripts = const [],
    this.onGlobalUserScriptsChanged,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen>
    with SingleTickerProviderStateMixin {
  late AppThemeSettings _settings;
  late bool _showTabStrip;
  late bool _showStatsBanner;
  bool _isDownloadingRules = false;
  DateTime? _rulesLastUpdated;

  // DNS Blocklist state
  bool _isDownloadingBlocklist = false;
  DateTime? _blocklistLastUpdated;
  int _dnsBlockLevel = 0; // Downloaded level
  double _dnsBlockSliderValue = 0; // Ephemeral slider value
  late AnimationController _spinController;

  // Content Blocker state
  String? _downloadingListId;

  // LocalCDN state
  int _localCdnCount = 0;
  String _localCdnSize = '0 B';
  bool _isDownloadingLocalCdn = false;
  bool _isClearingLocalCdn = false;
  DateTime? _localCdnLastUpdated;
  String _localCdnProgress = '';

  @override
  void initState() {
    super.initState();
    _settings = widget.currentSettings;
    _showTabStrip = widget.showTabStrip;
    _showStatsBanner = widget.showStatsBanner;
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _loadRulesLastUpdated();
    _loadBlocklistState();
    _loadLocalCdnState();
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
        // DnsBlockService fires a change listener that re-pushes domains
        // to the native interceptor; we only need to (re)attach webviews.
        await WebInterceptNative.attachToWebViews();
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

  Future<void> _downloadContentList(String id) async {
    setState(() {
      _downloadingListId = id;
    });

    final success = await ContentBlockerService.instance.downloadList(id);

    if (mounted) {
      setState(() {
        _downloadingListId = null;
      });

      if (success) {
        final list = ContentBlockerService.instance.lists
            .firstWhere((l) => l.id == id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content:
                  Text('${list.name}: ${_formatNumber(list.ruleCount)} rules')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download filter list')),
        );
      }
    }
  }

  Future<void> _downloadAllContentLists() async {
    setState(() {
      _downloadingListId = '__all__';
    });

    final count = await ContentBlockerService.instance.downloadAllLists();

    if (mounted) {
      setState(() {
        _downloadingListId = null;
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Updated $count filter lists')),
      );
    }
  }

  Future<void> _toggleContentList(String id, bool enabled) async {
    await ContentBlockerService.instance.toggleList(id, enabled);
    if (mounted) setState(() {});
  }

  Future<void> _removeContentList(String id) async {
    await ContentBlockerService.instance.removeList(id);
    if (mounted) setState(() {});
  }

  Future<void> _showAddCustomListDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Custom List'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g., My Custom List',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                labelText: 'URL',
                hintText: 'https://example.com/filters.txt',
              ),
              keyboardType: TextInputType.url,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (result == true &&
        nameController.text.isNotEmpty &&
        urlController.text.isNotEmpty) {
      final id = await ContentBlockerService.instance
          .addCustomList(nameController.text, urlController.text);
      await _downloadContentList(id);
    }

    nameController.dispose();
    urlController.dispose();
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

  Future<void> _loadLocalCdnState() async {
    final count = LocalCdnService.instance.resourceCount;
    final size = await LocalCdnService.instance.cacheSize;
    final lastUpdated = await LocalCdnService.instance.getLastUpdated();
    if (mounted) {
      setState(() {
        _localCdnCount = count;
        _localCdnSize = LocalCdnService.formatSize(size);
        _localCdnLastUpdated = lastUpdated;
      });
    }
  }

  Future<void> _downloadLocalCdnResources() async {
    setState(() {
      _isDownloadingLocalCdn = true;
      _localCdnProgress = '';
    });

    final downloaded = await LocalCdnService.instance.downloadPopularResources(
      onProgress: (completed, total) {
        if (mounted) {
          setState(() {
            _localCdnProgress = '$completed/$total';
          });
        }
      },
    );

    if (mounted) {
      setState(() {
        _isDownloadingLocalCdn = false;
        _localCdnProgress = '';
      });
      await _loadLocalCdnState();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Downloaded $downloaded resources')),
      );
    }
  }

  Future<void> _clearLocalCdnCache() async {
    setState(() {
      _isClearingLocalCdn = true;
    });

    await LocalCdnService.instance.clearCache();

    if (mounted) {
      setState(() {
        _isClearingLocalCdn = false;
      });
      await _loadLocalCdnState();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('LocalCDN cache cleared')),
      );
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

          // UI Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Interface',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Site Tab Strip'),
            subtitle: const Text('Show a tab bar at the bottom to quickly switch between sites'),
            value: _showTabStrip,
            onChanged: (value) {
              setState(() {
                _showTabStrip = value;
              });
              widget.onShowTabStripChanged(value);
            },
          ),
          SwitchListTile(
            title: const Text('Stats Bar'),
            subtitle: const Text('Show live request stats at the top of each site'),
            value: _showStatsBanner,
            onChanged: (value) {
              setState(() {
                _showStatsBanner = value;
              });
              widget.onShowStatsBannerChanged(value);
            },
          ),

          const Divider(height: 32),

          // User Scripts Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'User Scripts',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('Manage Scripts'),
            subtitle: Text(
              widget.globalUserScripts.isEmpty
                  ? 'No global scripts'
                  : '${widget.globalUserScripts.where((s) => s.enabled).length} active (all sites)',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserScriptsScreen(
                    title: 'User Scripts',
                    userScripts: widget.globalUserScripts,
                    onSave: (scripts) {
                      widget.onGlobalUserScriptsChanged?.call(scripts);
                    },
                  ),
                ),
              );
            },
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
            title: const Row(
              children: [
                Text('ClearURLs Rules'),
                HintButton(
                  title: 'ClearURLs',
                  description:
                      'Downloads a list of known tracking parameters used by websites (like utm_source, fbclid, etc.). '
                      'When enabled per-site, these parameters are automatically stripped from URLs to protect your privacy.',
                ),
              ],
            ),
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
                    icon: Icon(
                      _rulesLastUpdated != null
                          ? Icons.sync
                          : Icons.download,
                    ),
                    tooltip: _rulesLastUpdated != null
                        ? 'Update rules'
                        : 'Download rules',
                    onPressed: _downloadRules,
                  ),
          ),

          // DNS Blocklist
          ListTile(
            leading: const Icon(Icons.shield),
            title: const Row(
              children: [
                Text('DNS Blocklist'),
                HintButton(
                  title: 'DNS Blocklist',
                  description:
                      'Downloads the Hagezi blocklist to block known advertising, tracking, and malware domains. '
                      'Choose a severity level from Light to Ultimate. Higher levels block more domains but may break some sites. '
                      'Once downloaded, enable or disable per-site in each site\'s settings.',
                ),
              ],
            ),
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

          // LocalCDN (Android only)
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.storage),
              title: const Row(
                children: [
                  Text('LocalCDN'),
                  HintButton(
                    title: 'LocalCDN',
                    description:
                        'Downloads common JavaScript libraries, fonts, and CSS frameworks to serve locally '
                        'instead of fetching them from third-party CDN servers (like Google, Cloudflare, jsDelivr). '
                        'This prevents CDN providers from tracking your browsing across different websites.',
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _localCdnCount > 0
                        ? '$_localCdnCount resources ($_localCdnSize)'
                        : 'Not downloaded',
                  ),
                  if (_localCdnLastUpdated != null)
                    Text(
                      'Updated: ${_localCdnLastUpdated!.toLocal().toString().split('.')[0]}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  if (_isDownloadingLocalCdn && _localCdnProgress.isNotEmpty)
                    Text(
                      'Downloading $_localCdnProgress...',
                      style: const TextStyle(fontSize: 12),
                    ),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_isDownloadingLocalCdn || _isClearingLocalCdn)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else ...[
                    IconButton(
                      icon: Icon(
                        _localCdnCount > 0 ? Icons.sync : Icons.download,
                      ),
                      tooltip: _localCdnCount > 0
                          ? 'Update resources'
                          : 'Download resources',
                      onPressed: _downloadLocalCdnResources,
                    ),
                    if (_localCdnCount > 0)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'Clear cache',
                        onPressed: _clearLocalCdnCache,
                      ),
                  ],
                ],
              ),
            ),

          // Content Blocker
          const Divider(height: 32),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        'Content Blocker',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const HintButton(
                        title: 'Content Blocker',
                        description:
                            'Blocks ads, trackers, and unwanted page elements using filter lists like EasyList. '
                            'Supports domain-level blocking, CSS cosmetic filters to hide page elements, '
                            'and text-based hiding rules. Enable or disable individual filter lists below, '
                            'and toggle content blocking per-site in each site\'s settings.',
                      ),
                    ],
                  ),
                ),
                if (ContentBlockerService.instance.lists
                    .any((l) => l.enabled))
                  _downloadingListId == '__all__'
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child:
                              CircularProgressIndicator(strokeWidth: 2),
                        )
                      : IconButton(
                          icon: const Icon(Icons.sync),
                          tooltip: 'Update all lists',
                          onPressed: _downloadingListId != null
                              ? null
                              : _downloadAllContentLists,
                        ),
              ],
            ),
          ),
          ...ContentBlockerService.instance.lists.map((list) {
            final isDownloading = _downloadingListId == list.id ||
                _downloadingListId == '__all__';
            final isDefault = !list.id.startsWith('custom_');

            return ListTile(
              leading: Switch(
                value: list.enabled,
                onChanged: list.lastUpdated != null && !isDownloading
                    ? (value) => _toggleContentList(list.id, value)
                    : null,
              ),
              title: Text(list.name),
              subtitle: Text(
                list.lastUpdated != null
                    ? '${_formatNumber(list.ruleCount)} rules'
                    : 'Not downloaded',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isDownloading)
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    IconButton(
                      icon: Icon(
                        list.lastUpdated != null
                            ? Icons.sync
                            : Icons.download,
                      ),
                      tooltip: list.lastUpdated != null
                          ? 'Refresh'
                          : 'Download',
                      onPressed: _downloadingListId != null
                          ? null
                          : () => _downloadContentList(list.id),
                    ),
                  if (!isDefault)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove',
                      onPressed: _downloadingListId != null
                          ? null
                          : () => _removeContentList(list.id),
                    ),
                ],
              ),
            );
          }),
          Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: OutlinedButton.icon(
              onPressed:
                  _downloadingListId != null ? null : _showAddCustomListDialog,
              icon: const Icon(Icons.add),
              label: const Text('Add Custom List'),
            ),
          ),

          const Divider(height: 32),

          // Developer Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Developer',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: const Text('App Logs'),
            subtitle: const Text('View app-level debug logs'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => DevToolsScreen(
                    cookieManager: CookieManager(),
                  ),
                ),
              );
            },
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
            onTap: () async {
              final packageInfo = await PackageInfo.fromPlatform();
              if (!context.mounted) return;
              showLicensePage(
                context: context,
                applicationName: 'WebSpace',
                applicationVersion: packageInfo.version,
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
