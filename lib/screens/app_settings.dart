import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/main.dart' show AppThemeSettings, AccentColor;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/screens/trusted_certificates.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
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
  /// Prompt the user for a passphrase and open or create the matching
  /// archive (spec `openspec/specs/archive/spec.md`). Wired by the
  /// parent so the dialog runs in the main-page navigator (matching the
  /// import/export pattern).
  final VoidCallback? onRestoreArchive;
  /// True when at least one archive is currently open in the running
  /// process. The "Close all archives" tile is shown only when true;
  /// its absence does not indicate whether any archives exist on disk.
  final bool hasOpenArchives;
  final VoidCallback? onCloseAllArchives;
  final bool showTabStrip;
  final ValueChanged<bool> onShowTabStripChanged;
  final bool tabStripInFullscreen;
  final ValueChanged<bool> onTabStripInFullscreenChanged;
  final bool showStatsBanner;
  final ValueChanged<bool> onShowStatsBannerChanged;
  /// Current UI language override as a locale tag ('' = follow system).
  final String localeOverride;
  final ValueChanged<String> onLocaleOverrideChanged;
  /// LIR-008: master "Handle shared links" switch + entry into the
  /// routing overview screen. The wrapping page handles persistence.
  final bool linkHandlingEnabled;
  final ValueChanged<bool> onLinkHandlingEnabledChanged;
  final VoidCallback onOpenLinkHandlingSettings;
  final List<UserScriptConfig> globalUserScripts;
  final void Function(List<UserScriptConfig>)? onGlobalUserScriptsChanged;
  /// Fired after the global outbound proxy is updated. Parent should
  /// dispose every loaded webview so the next render re-applies the new
  /// proxy: on Android the singleton `inapp.ProxyController` only refreshes
  /// when `setProxySettings` is called again (which happens in
  /// [WebViewModel.setController]), and on iOS / macOS / Linux the proxy
  /// is sealed into the per-site `WKWebsiteDataStore` /
  /// `WebKitNetworkSession` at WebView construction. Without this the
  /// "global proxy applies via DEFAULT fallthrough" contract advertised
  /// in the UI hint silently doesn't take effect until the next app
  /// restart.
  final VoidCallback? onOutboundProxyChanged;

  const AppSettingsScreen({
    super.key,
    required this.currentSettings,
    required this.onSettingsChanged,
    required this.onExportSettings,
    required this.onImportSettings,
    this.onRestoreArchive,
    this.hasOpenArchives = false,
    this.onCloseAllArchives,
    required this.showTabStrip,
    required this.onShowTabStripChanged,
    required this.tabStripInFullscreen,
    required this.onTabStripInFullscreenChanged,
    required this.showStatsBanner,
    required this.onShowStatsBannerChanged,
    required this.localeOverride,
    required this.onLocaleOverrideChanged,
    required this.linkHandlingEnabled,
    required this.onLinkHandlingEnabledChanged,
    required this.onOpenLinkHandlingSettings,
    this.globalUserScripts = const [],
    this.onGlobalUserScriptsChanged,
    this.onOutboundProxyChanged,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen>
    with SingleTickerProviderStateMixin {
  late AppThemeSettings _settings;
  late bool _showTabStrip;
  late bool _tabStripInFullscreen;
  late bool _showStatsBanner;
  late TextEditingController _osmTileUrlController;
  bool _isDownloadingRules = false;
  DateTime? _rulesLastUpdated;

  // Timezone polygon dataset state (per-site "From picked location" timezone option)
  bool _isDownloadingTimezones = false;
  DateTime? _timezonesLastUpdated;
  int _timezoneZoneCount = 0;

  // Global outbound proxy state. Mirrors the per-site proxy UI in
  // [lib/screens/settings.dart] but applies to *every* Dart-side outbound
  // call (DNS blocklist downloads, ClearURLs rules, content blocker rules,
  // LocalCDN catalog, OSM map tiles in the location picker, etc.) and
  // also acts as the fallthrough for any per-site proxy whose type is
  // [ProxyType.DEFAULT].
  late UserProxySettings _outboundProxy;
  late TextEditingController _outboundProxyAddressController;
  late TextEditingController _outboundProxyUsernameController;
  late TextEditingController _outboundProxyPasswordController;
  bool _outboundProxyShowCredentials = false;
  bool _outboundProxyObscurePassword = true;
  /// Snapshot of the outbound proxy fields at last persisted state. Most
  /// of this screen auto-applies on change, but the proxy text fields only
  /// flush via `onEditingComplete` / `onFieldSubmitted`, so a user who
  /// types a partial value and pops via the system back gesture would
  /// silently lose the edit. [_isOutboundProxyDirty] drives the PopScope
  /// guard so we prompt instead.
  late Map<String, Object?> _initialOutboundProxy;

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
    _tabStripInFullscreen = widget.tabStripInFullscreen;
    _showStatsBanner = widget.showStatsBanner;
    _osmTileUrlController = TextEditingController();
    _loadOsmTileUrl();
    _outboundProxy = UserProxySettings(
      type: GlobalOutboundProxy.current.type,
      address: GlobalOutboundProxy.current.address,
      username: GlobalOutboundProxy.current.username,
      password: GlobalOutboundProxy.current.password,
    );
    _outboundProxyAddressController = TextEditingController(
      text: _outboundProxy.address ?? '',
    );
    _outboundProxyUsernameController = TextEditingController(
      text: _outboundProxy.username ?? '',
    );
    _outboundProxyPasswordController = TextEditingController(
      text: _outboundProxy.password ?? '',
    );
    _outboundProxyShowCredentials = _outboundProxy.hasCredentials;
    _initialOutboundProxy = _currentOutboundProxySnapshot();
    _outboundProxyAddressController.addListener(_onProxyFieldChanged);
    _outboundProxyUsernameController.addListener(_onProxyFieldChanged);
    _outboundProxyPasswordController.addListener(_onProxyFieldChanged);
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _loadRulesLastUpdated();
    _loadBlocklistState();
    _loadLocalCdnState();
    _loadTimezoneState();
  }

  Future<void> _loadTimezoneState() async {
    final lastUpdated = await TimezoneLocationService.instance.getLastUpdated();
    if (!mounted) return;
    setState(() {
      _timezonesLastUpdated = lastUpdated;
      _timezoneZoneCount = TimezoneLocationService.instance.zoneCount;
    });
  }

  Future<void> _downloadTimezones() async {
    setState(() => _isDownloadingTimezones = true);
    _spinController.repeat();
    final success = await TimezoneLocationService.instance.download();
    if (!mounted) return;
    _spinController.stop();
    _spinController.reset();
    setState(() {
      _isDownloadingTimezones = false;
      _timezoneZoneCount = TimezoneLocationService.instance.zoneCount;
    });
    final loc = AppLocalizations.of(context);
    if (success) {
      _timezonesLastUpdated =
          await TimezoneLocationService.instance.getLastUpdated();
      if (mounted) setState(() {});
      rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
          content: Text(loc.appSettingsTimezonesLoaded(_timezoneZoneCount))));
    } else {
      rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
          content: Text(loc.appSettingsTimezonesDownloadFailed)));
    }
  }

  Future<void> _clearTimezones() async {
    await TimezoneLocationService.instance.clear();
    if (!mounted) return;
    setState(() {
      _timezonesLastUpdated = null;
      _timezoneZoneCount = 0;
    });
  }

  @override
  void dispose() {
    _osmTileUrlController.dispose();
    _outboundProxyAddressController.dispose();
    _outboundProxyUsernameController.dispose();
    _outboundProxyPasswordController.dispose();
    _spinController.dispose();
    super.dispose();
  }

  String? _validateOutboundProxyAddress(String value) {
    final loc = AppLocalizations.of(context);
    if (_outboundProxy.type == ProxyType.DEFAULT) return null;
    final trimmed = value.trim();
    if (trimmed.isEmpty) return loc.appSettingsProxyAddressRequired;
    final parts = trimmed.split(':');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) {
      return loc.appSettingsProxyFormatHostPort;
    }
    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) {
      return loc.appSettingsProxyInvalidPort;
    }
    return null;
  }

  Future<void> _saveOutboundProxy() async {
    final address = _outboundProxyAddressController.text.trim();
    if (_outboundProxy.type != ProxyType.DEFAULT) {
      final err = _validateOutboundProxyAddress(address);
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
        return;
      }
    }
    final settings = UserProxySettings(
      type: _outboundProxy.type,
      address: _outboundProxy.type == ProxyType.DEFAULT ? null : address,
      username: _outboundProxyShowCredentials &&
              _outboundProxy.type != ProxyType.DEFAULT
          ? _outboundProxyUsernameController.text
          : null,
      password: _outboundProxyShowCredentials &&
              _outboundProxy.type != ProxyType.DEFAULT
          ? _outboundProxyPasswordController.text
          : null,
    );
    final previous = GlobalOutboundProxy.current;
    final changed = previous.type != settings.type ||
        previous.address != settings.address ||
        previous.username != settings.username ||
        previous.password != settings.password;
    await GlobalOutboundProxy.update(settings);
    setState(() {
      _outboundProxy = settings;
      _initialOutboundProxy = _currentOutboundProxySnapshot();
    });
    // Force every loaded webview to be rebuilt so the new global proxy
    // takes effect immediately. Without this the change only applies to
    // sites loaded after the next app restart — webview navigation keeps
    // routing through the stale proxy bound at construction time.
    // Skip the reset on no-op edits (e.g. focus leaves a field that was
    // never modified) so we don't churn webviews while the user is
    // tabbing through.
    if (changed) {
      LogService.instance.log(
        'Proxy',
        'Outbound proxy changed; resetting all loaded webviews so the new '
            'value is applied on next render',
        level: LogLevel.info,
        sensitivity: LogSensitivity.sensitive,
      );
      widget.onOutboundProxyChanged?.call();
    } else {
      LogService.instance.log(
        'Proxy',
        'Outbound proxy save invoked but settings unchanged; skipping webview reset',
        sensitivity: LogSensitivity.sensitive,
      );
    }
    if (mounted && changed) {
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsOutboundProxyUpdated)),
      );
    }
  }

  void _onProxyFieldChanged() {
    if (mounted) setState(() {});
  }

  Map<String, Object?> _currentOutboundProxySnapshot() => {
        'type': _outboundProxy.type,
        'address': _outboundProxyAddressController.text,
        'username': _outboundProxyUsernameController.text,
        'password': _outboundProxyPasswordController.text,
        'showCreds': _outboundProxyShowCredentials,
      };

  bool _isOutboundProxyDirty() {
    final cur = _currentOutboundProxySnapshot();
    for (final key in _initialOutboundProxy.keys) {
      if (cur[key] != _initialOutboundProxy[key]) return true;
    }
    return false;
  }

  Future<bool> _confirmDiscardProxy() async {
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.appSettingsDiscardChangesTitle),
        content: Text(loc.appSettingsDiscardProxyBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.appSettingsKeepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              loc.appSettingsDiscard,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
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

      final loc = AppLocalizations.of(context);
      if (success) {
        await _loadBlocklistState();
        // DnsBlockService fires a change listener that re-pushes domains
        // to the native interceptor; we only need to (re)attach webviews.
        await WebInterceptNative.attachToWebViews();
        final domainCount = DnsBlockService.instance.domainCount;
        final message = level == 0
            ? loc.appSettingsDnsBlocklistDisabled
            : loc.appSettingsDnsBlocklistUpdated(_formatNumber(domainCount));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.appSettingsDnsBlocklistDownloadFailed)),
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

      final loc = AppLocalizations.of(context);
      if (success) {
        final list = ContentBlockerService.instance.lists
            .firstWhere((l) => l.id == id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(loc.appSettingsFilterListRules(
                  list.name, _formatNumber(list.ruleCount)))),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.appSettingsFilterListDownloadFailed)),
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

      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsFilterListsUpdated(count))),
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

    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(loc.appSettingsAddCustomListTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: InputDecoration(
                labelText: loc.appSettingsCustomListNameLabel,
                hintText: loc.appSettingsCustomListNameHint,
              ),
            ),
            const SizedBox(height: 8),
            Builder(builder: (context) {
              const urlHint = 'https://example.com/filters.txt';
              return TextField(
                controller: urlController,
                decoration: InputDecoration(
                  labelText: loc.appSettingsCustomListUrlLabel,
                  hintText: urlHint,
                ),
                keyboardType: TextInputType.url,
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(loc.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(loc.commonAdd),
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

  Future<void> _loadOsmTileUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('osmTileUrl') ??
        'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
    if (!mounted) return;
    _osmTileUrlController.text = url;
  }

  Future<void> _saveOsmTileUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await prefs.remove('osmTileUrl');
    } else {
      await prefs.setString('osmTileUrl', trimmed);
    }
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

      final loc = AppLocalizations.of(context);
      if (success) {
        await _loadRulesLastUpdated();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.appSettingsClearUrlsUpdated)),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.appSettingsClearUrlsDownloadFailed)),
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
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsLocalCdnDownloaded(downloaded))),
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
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsLocalCdnCacheCleared)),
      );
    }
  }

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
                groupValue: widget.localeOverride,
                title: Text(loc.appSettingsLanguageSystem),
                onChanged: (v) => Navigator.pop(ctx, v ?? ''),
              ),
              for (final tag in tags)
                RadioListTile<String>(
                  value: tag,
                  groupValue: widget.localeOverride,
                  title: Text(languageLabelForTag(tag)),
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null) return;
    widget.onLocaleOverrideChanged(selected);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return PopScope(
      canPop: !_isOutboundProxyDirty(),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await _confirmDiscardProxy();
        if (discard != true || !mounted) return;
        setState(() {
          _initialOutboundProxy = _currentOutboundProxySnapshot();
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        navigator.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(loc.appSettingsTitle),
      ),
      body: ListView(
        children: [
          // Theme Mode Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              loc.appSettingsTheme,
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
              loc.appSettingsAccentColor,
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
              loc.appSettingsInterface,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SwitchListTile(
            title: Text(loc.appSettingsSiteTabStrip),
            subtitle: Text(loc.appSettingsSiteTabStripSubtitle),
            value: _showTabStrip,
            onChanged: (value) {
              setState(() {
                _showTabStrip = value;
              });
              widget.onShowTabStripChanged(value);
            },
          ),
          SwitchListTile(
            title: Text(loc.appSettingsKeepTabStripFullscreen),
            subtitle: Text(loc.appSettingsKeepTabStripFullscreenSubtitle),
            value: _tabStripInFullscreen,
            onChanged: _showTabStrip
                ? (value) {
                    setState(() {
                      _tabStripInFullscreen = value;
                    });
                    widget.onTabStripInFullscreenChanged(value);
                  }
                : null,
          ),
          SwitchListTile(
            title: Text(loc.appSettingsStatsBar),
            subtitle: Text(loc.appSettingsStatsBarSubtitle),
            value: _showStatsBanner,
            onChanged: (value) {
              setState(() {
                _showStatsBanner = value;
              });
              widget.onShowStatsBannerChanged(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.language),
            title: Text(loc.appSettingsLanguageTitle),
            subtitle: Text(widget.localeOverride.isEmpty
                ? loc.appSettingsLanguageSystem
                : languageLabelForTag(widget.localeOverride)),
            trailing: const Icon(Icons.chevron_right),
            onTap: _pickAppLanguage,
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: Text(loc.appSettingsLinkHandling),
            subtitle: Text(widget.linkHandlingEnabled
                ? loc.appSettingsLinkHandlingOn
                : loc.appSettingsLinkHandlingOff),
            trailing: const Icon(Icons.chevron_right),
            onTap: widget.onOpenLinkHandlingSettings,
          ),
          const Divider(height: 32),
          // Global outbound proxy section
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Text(
                  loc.appSettingsOutboundProxy,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                HintButton(
                  title: loc.appSettingsOutboundProxy,
                  description: loc.appSettingsOutboundProxyHint,
                ),
              ],
            ),
          ),
          ListTile(
            title: Text(loc.appSettingsProxyType),
            trailing: DropdownButton<ProxyType>(
              value: _outboundProxy.type,
              onChanged: (newValue) {
                if (newValue == null) return;
                setState(() {
                  _outboundProxy.type = newValue;
                });
                _saveOutboundProxy();
              },
              items: ProxyType.values
                  .map((v) => DropdownMenuItem(
                        value: v,
                        child: Text(v.toString().split('.').last),
                      ))
                  .toList(),
            ),
          ),
          if (_outboundProxy.type != ProxyType.DEFAULT) ...[
            Padding(
              padding: const EdgeInsets.symmetric(
                  horizontal: 16.0, vertical: 8.0),
              child: TextFormField(
                controller: _outboundProxyAddressController,
                decoration: InputDecoration(
                  labelText: loc.appSettingsProxyAddress,
                  hintText: loc.appSettingsProxyAddressHint,
                  helperText: loc.appSettingsProxyAddressHelper,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: (_) => _saveOutboundProxy(),
                onEditingComplete: _saveOutboundProxy,
              ),
            ),
            CheckboxListTile(
              title: Text(loc.appSettingsProxyRequiresAuth),
              value: _outboundProxyShowCredentials,
              onChanged: (v) {
                setState(() {
                  _outboundProxyShowCredentials = v ?? false;
                });
                _saveOutboundProxy();
              },
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_outboundProxyShowCredentials) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 8.0),
                child: TextFormField(
                  controller: _outboundProxyUsernameController,
                  decoration: InputDecoration(
                    labelText: loc.appSettingsProxyUsername,
                    border: const OutlineInputBorder(),
                  ),
                  onFieldSubmitted: (_) => _saveOutboundProxy(),
                  onEditingComplete: _saveOutboundProxy,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16.0, vertical: 8.0),
                child: TextFormField(
                  controller: _outboundProxyPasswordController,
                  obscureText: _outboundProxyObscurePassword,
                  decoration: InputDecoration(
                    labelText: loc.appSettingsProxyPassword,
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_outboundProxyObscurePassword
                          ? Icons.visibility
                          : Icons.visibility_off),
                      onPressed: () {
                        setState(() {
                          _outboundProxyObscurePassword =
                              !_outboundProxyObscurePassword;
                        });
                      },
                    ),
                  ),
                  onFieldSubmitted: (_) => _saveOutboundProxy(),
                  onEditingComplete: _saveOutboundProxy,
                ),
              ),
            ],
          ],

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Text(
                  loc.appSettingsLocationPicker,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                HintButton(
                  title: loc.appSettingsLocationPicker,
                  description: loc.appSettingsLocationPickerHint,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Builder(builder: (context) {
              const tileUrlHint =
                  'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
              return TextFormField(
                controller: _osmTileUrlController,
                decoration: InputDecoration(
                  labelText: loc.appSettingsTileUrl,
                  hintText: tileUrlHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: _saveOsmTileUrl,
              );
            }),
          ),

          // Timezone polygon dataset — opt-in download enabling the
          // "From picked location" timezone option in per-site settings.
          // Modeled on the DNS blocklist pattern: status + download/refresh
          // button, plus a clear button when data is present.
          ListTile(
            leading: const Icon(Icons.public),
            title: Row(
              children: [
                Text(loc.appSettingsTimezonePolygons),
                HintButton(
                  title: loc.appSettingsTimezonePolygons,
                  description: loc.appSettingsTimezonePolygonsHint,
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_timezoneZoneCount > 0
                    ? loc.appSettingsZonesCount(_formatNumber(_timezoneZoneCount))
                    : loc.appSettingsNotDownloaded),
                if (_timezonesLastUpdated != null)
                  Builder(builder: (context) {
                    final updated = _timezonesLastUpdated!
                        .toLocal()
                        .toString()
                        .split('.')[0];
                    return Text(
                      loc.appSettingsUpdatedAt(updated),
                      style: const TextStyle(fontSize: 12),
                    );
                  }),
              ],
            ),
            trailing: _isDownloadingTimezones
                ? RotationTransition(
                    turns: _spinController,
                    child: const Icon(Icons.sync),
                  )
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_timezoneZoneCount > 0)
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: loc.appSettingsClearDataset,
                          onPressed: _clearTimezones,
                        ),
                      IconButton(
                        icon: Icon(_timezoneZoneCount > 0
                            ? Icons.sync
                            : Icons.download),
                        tooltip: _timezoneZoneCount > 0
                            ? loc.appSettingsRefreshDataset
                            : loc.appSettingsDownloadDataset,
                        onPressed: _downloadTimezones,
                      ),
                    ],
                  ),
          ),

          const Divider(height: 32),

          // User Scripts Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              loc.appSettingsUserScripts,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.code),
            title: Text(loc.appSettingsManageScripts),
            subtitle: Text(
              widget.globalUserScripts.isEmpty
                  ? loc.appSettingsNoGlobalScripts
                  : loc.appSettingsScriptsDefined(widget.globalUserScripts.length),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserScriptsScreen(
                    title: 'Global User Scripts',
                    userScripts: widget.globalUserScripts,
                    onSave: (scripts) {
                      widget.onGlobalUserScriptsChanged?.call(scripts);
                    },
                    isGlobalLibrary: true,
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
              loc.appSettingsData,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.upload),
            title: Text(loc.appSettingsExportSettings),
            subtitle: Text(loc.appSettingsExportSettingsSubtitle),
            onTap: () {
              Navigator.pop(context);
              widget.onExportSettings();
            },
          ),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(loc.appSettingsImportSettings),
            subtitle: Text(loc.appSettingsImportSettingsSubtitle),
            onTap: () {
              Navigator.pop(context);
              widget.onImportSettings();
            },
          ),
          if (widget.onRestoreArchive != null)
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: Text(loc.appSettingsRestoreArchive),
              subtitle: Text(loc.appSettingsRestoreArchiveSubtitle),
              onTap: () {
                Navigator.pop(context);
                widget.onRestoreArchive!();
              },
            ),
          if (widget.hasOpenArchives && widget.onCloseAllArchives != null)
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(loc.appSettingsCloseAllArchives),
              subtitle: Text(loc.appSettingsCloseAllArchivesSubtitle),
              onTap: () {
                Navigator.pop(context);
                widget.onCloseAllArchives!();
              },
            ),

          const Divider(height: 32),

          // Privacy Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              loc.appSettingsPrivacy,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          // Trusted certificates — only Android and Linux can create
          // pins via the in-app prompt. On iOS/macOS the prompt is
          // skipped entirely (TLS-009) because Apple's WKWebView
          // rejects every URLCredential(trust:) override, so the list
          // would always be empty there. Imported pins from a backup
          // still apply via HttpClient.badCertificateCallback even on
          // Apple platforms, but the rare "inspect-imported-pins-on-
          // iOS" case doesn't justify an always-empty settings tile.
          if (Platform.isAndroid || Platform.isLinux)
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Row(
                children: [
                  Text(loc.appSettingsTrustedCertificates),
                  HintButton(
                    title: loc.appSettingsTrustedCertificates,
                    description: loc.appSettingsTrustedCertificatesHint,
                  ),
                ],
              ),
              subtitle: Text(loc.appSettingsTrustedCertificatesSubtitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const TrustedCertificatesScreen(),
                  ),
                );
              },
            ),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: Row(
              children: [
                Text(loc.appSettingsClearUrlsRules),
                HintButton(
                  title: loc.appSettingsClearUrlsRules,
                  description: loc.appSettingsClearUrlsHint,
                ),
              ],
            ),
            subtitle: Builder(builder: (context) {
              final updated = _rulesLastUpdated
                  ?.toLocal()
                  .toString()
                  .split('.')[0];
              return Text(
                updated != null
                    ? loc.appSettingsUpdatedAt(updated)
                    : loc.appSettingsNotDownloaded,
              );
            }),
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
                        ? loc.appSettingsUpdateRules
                        : loc.appSettingsDownloadRules,
                    onPressed: _downloadRules,
                  ),
          ),

          // DNS Blocklist
          ListTile(
            leading: const Icon(Icons.shield),
            title: Row(
              children: [
                Text(loc.appSettingsDnsBlocklist),
                HintButton(
                  title: loc.appSettingsDnsBlocklist,
                  description: loc.appSettingsDnsBlocklistHint,
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _dnsBlockLevel > 0
                      ? loc.appSettingsDnsBlockLevelDomains(
                          dnsBlockLevelNames[_dnsBlockLevel],
                          _formatNumber(DnsBlockService.instance.domainCount))
                      : loc.appSettingsNotConfigured,
                ),
                if (_blocklistLastUpdated != null)
                  Builder(builder: (context) {
                    final updated = _blocklistLastUpdated!
                        .toLocal()
                        .toString()
                        .split('.')[0];
                    return Text(
                      loc.appSettingsUpdatedAt(updated),
                      style: const TextStyle(fontSize: 12),
                    );
                  }),
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
                        ? loc.appSettingsDownloadBlocklist
                        : loc.appSettingsRefreshBlocklist,
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
              title: Row(
                children: [
                  Text(loc.appSettingsLocalCdn),
                  HintButton(
                    title: loc.appSettingsLocalCdn,
                    description: loc.appSettingsLocalCdnHint,
                  ),
                ],
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _localCdnCount > 0
                        ? loc.appSettingsLocalCdnResources(
                            _localCdnCount, _localCdnSize)
                        : loc.appSettingsNotDownloaded,
                  ),
                  if (_localCdnLastUpdated != null)
                    Builder(builder: (context) {
                      final updated = _localCdnLastUpdated!
                          .toLocal()
                          .toString()
                          .split('.')[0];
                      return Text(
                        loc.appSettingsUpdatedAt(updated),
                        style: const TextStyle(fontSize: 12),
                      );
                    }),
                  if (_isDownloadingLocalCdn && _localCdnProgress.isNotEmpty)
                    Text(
                      loc.appSettingsDownloadingProgress(_localCdnProgress),
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
                          ? loc.appSettingsUpdateResources
                          : loc.appSettingsDownloadResources,
                      onPressed: _downloadLocalCdnResources,
                    ),
                    if (_localCdnCount > 0)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: loc.appSettingsClearCache,
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
                        loc.appSettingsContentBlocker,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      HintButton(
                        title: loc.appSettingsContentBlocker,
                        description: loc.appSettingsContentBlockerHint,
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
                          tooltip: loc.appSettingsUpdateAllLists,
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
                    ? loc.appSettingsRulesCount(_formatNumber(list.ruleCount))
                    : loc.appSettingsNotDownloaded,
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
                          ? loc.appSettingsRefresh
                          : loc.appSettingsDownload,
                      onPressed: _downloadingListId != null
                          ? null
                          : () => _downloadContentList(list.id),
                    ),
                  if (!isDefault)
                    IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: loc.commonRemove,
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
              label: Text(loc.appSettingsAddCustomList),
            ),
          ),
          // uBO resources toggle. When off, $redirect= rules become
          // plain blocks (drop the request) instead of returning a stub
          // body. Some ad/tracker sites detect the missing API surface
          // and break (white page, infinite spinner), so default on.
          // Greyed out on platforms that don't ship the engine library.
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.appSettingsUboRedirectStubs)),
                HintButton(
                  title: loc.appSettingsUboRedirectStubs,
                  description: loc.appSettingsUboRedirectStubsSubtitle,
                ),
              ],
            ),
            subtitle:
                !ContentBlockerService.instance.rustEngineSupportedOnPlatform
                    ? Text(loc.appSettingsUboRedirectStubsUnavailable)
                    : null,
            value: ContentBlockerService.instance.useUboResources,
            onChanged: ContentBlockerService.instance
                    .rustEngineSupportedOnPlatform
                ? (value) async {
                    await ContentBlockerService.instance
                        .setUseUboResources(value);
                    if (mounted) setState(() {});
                  }
                : null,
          ),

          const Divider(height: 32),

          // Developer Section
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              loc.appSettingsDeveloper,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(loc.appSettingsAppLogs),
            subtitle: Text(loc.appSettingsAppLogsSubtitle),
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
              loc.appSettingsAbout,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(loc.appSettingsLicenses),
            subtitle: Text(loc.appSettingsLicensesSubtitle),
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
      ),
    );
  }

  Widget _buildThemeModeRow() {
    final loc = AppLocalizations.of(context);
    return Row(
      children: [
        Expanded(
          child: _buildThemeModeChip(
            ThemeMode.light,
            loc.appSettingsThemeLight,
            Icons.wb_sunny,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildThemeModeChip(
            ThemeMode.dark,
            loc.appSettingsThemeDark,
            Icons.nights_stay,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildThemeModeChip(
            ThemeMode.system,
            loc.appSettingsThemeSystem,
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
