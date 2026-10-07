import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/screens/content_blocker_settings.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/ubo_backup_import.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/widgets/firefox_version_tile.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/level_slider.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/widgets/settings_rows.dart';

/// The names of the app-wide protections that are on, for the App Settings
/// row. Same shape as the Privacy row in site settings.
List<String> appPrivacyOn(
  AppLocalizations loc, {
  required bool httpsUpgradeEnabled,
  required bool blockScreenshots,
}) =>
    [
      if (httpsUpgradeEnabled) loc.siteSettingsHttpsUpgrade,
      if (DnsBlockService.instance.level > 0) loc.appSettingsDnsBlocklist,
      if (ContentBlockerService.instance.lists.any((l) => l.enabled))
        loc.appSettingsContentBlocker,
      if (hostIsAndroid && LocalCdnService.instance.resourceCount > 0)
        loc.appSettingsLocalCdn,
      if (ScreenCaptureGuard.isSupported && blockScreenshots)
        loc.siteSettingsBlockScreenshots,
    ];

/// What every site may learn or keep: the app-wide blockers each site's own
/// Privacy screen masks, the identity data its spoofing draws on, and screen
/// capture.
class AppPrivacyScreen extends StatefulWidget {
  const AppPrivacyScreen({
    super.key,
    this.siteNames = const {},
    required this.showStatsBanner,
    required this.onShowStatsBannerChanged,
    required this.httpsUpgradeEnabled,
    required this.onHttpsUpgradeEnabledChanged,
    this.blockScreenshots = false,
    this.onBlockScreenshotsChanged,
    this.onTrustUboHosts,
  });

  /// `siteId` -> display name, passed through to the protection report so its
  /// per-category drill-down can name the sites a block was recorded for.
  final Map<String, String> siteNames;
  final bool showStatsBanner;
  final ValueChanged<bool> onShowStatsBannerChanged;

  /// HTTPS-005: app-wide default for retrying a plain-http navigation over
  /// https. A site can override it; Tracking Protection forces it on.
  final bool httpsUpgradeEnabled;
  final ValueChanged<bool> onHttpsUpgradeEnabledChanged;

  /// SCREENBLOCK-002: withhold the whole app from screen capture.
  final bool blockScreenshots;
  final ValueChanged<bool>? onBlockScreenshotsChanged;

  /// See [ContentBlockerSettingsScreen.onTrustUboHosts].
  final Future<List<UboTrustedSite>> Function(Set<String> hosts,
      {required bool apply})? onTrustUboHosts;

  @override
  State<AppPrivacyScreen> createState() => _AppPrivacyScreenState();
}

class _AppPrivacyScreenState extends State<AppPrivacyScreen>
    with SingleTickerProviderStateMixin, SettingsOpenGuard {
  late bool _showStatsBanner = widget.showStatsBanner;
  late bool _httpsUpgradeEnabled = widget.httpsUpgradeEnabled;
  late bool _blockScreenshots = widget.blockScreenshots;
  final TextEditingController _osmTileUrlController = TextEditingController();
  late final AnimationController _spinController;

  bool _isDownloadingRules = false;
  DateTime? _rulesLastUpdated;

  bool _isUpdatingFirefoxVersion = false;
  bool _firefoxAutoRefresh = false;

  // Timezone polygon dataset state (per-site "From picked location" timezone option)
  bool _isDownloadingTimezones = false;
  bool _timezonesCached = false;
  DateTime? _timezonesLastUpdated;
  int? _timezoneZoneCount;
  int _timezoneStateVersion = 0;

  // DNS Blocklist state
  bool _isDownloadingBlocklist = false;
  DateTime? _blocklistLastUpdated;
  int _dnsBlockLevel = 0; // Downloaded level
  int _dnsBlockSliderValue = 0; // Ephemeral slider value

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
    _spinController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _loadOsmTileUrl();
    _loadFirefoxAutoRefresh();
    _loadRulesLastUpdated();
    _loadBlocklistState();
    _loadLocalCdnState();
    TimezoneLocationService.instance.addListener(_onTimezoneDatasetChanged);
    _loadTimezoneState();
  }

  @override
  void dispose() {
    _osmTileUrlController.dispose();
    _spinController.dispose();
    TimezoneLocationService.instance.removeListener(_onTimezoneDatasetChanged);
    super.dispose();
  }

  void _onTimezoneDatasetChanged() => _loadTimezoneState();

  // Reads the dataset on disk, not the in-memory one: only the lookup paths
  // load it, so a downloaded dataset is usually not in memory here.
  Future<void> _loadTimezoneState() async {
    final version = ++_timezoneStateVersion;
    final service = TimezoneLocationService.instance;
    final cached = await service.hasCachedDataset();
    final lastUpdated = await service.getLastUpdated();
    if (!mounted || version != _timezoneStateVersion) return;
    setState(() {
      _timezonesCached = cached;
      _timezonesLastUpdated = lastUpdated;
      if (!cached) _timezoneZoneCount = null;
    });
    if (!cached) return;
    final count = await service.cachedZoneCount();
    if (!mounted || version != _timezoneStateVersion) return;
    setState(() {
      _timezonesCached = count != null;
      _timezoneZoneCount = count;
    });
  }

  Future<void> _downloadTimezones() async {
    if (_isDownloadingTimezones) return;
    setState(() => _isDownloadingTimezones = true);
    _spinController.repeat();
    final success = await TimezoneLocationService.instance.download();
    if (!mounted) return;
    _spinController.stop();
    _spinController.reset();
    setState(() => _isDownloadingTimezones = false);
    final loc = AppLocalizations.of(context);
    rootScaffoldMessengerKey.currentState?.showSnackBar(SnackBar(
        content: Text(success
            ? loc.appSettingsTimezonesLoaded(
                TimezoneLocationService.instance.zoneCount)
            : loc.appSettingsTimezonesDownloadFailed)));
  }

  Future<void> _loadBlocklistState() async {
    final lastUpdated = await DnsBlockService.instance.getLastUpdated();
    if (mounted) {
      setState(() {
        _dnsBlockLevel = DnsBlockService.instance.level;
        _dnsBlockSliderValue = _dnsBlockLevel;
        _blocklistLastUpdated = lastUpdated;
      });
    }
  }

  Future<void> _downloadBlocklist() async {
    if (_isDownloadingBlocklist) return;
    final level = _dnsBlockSliderValue;

    setState(() {
      _isDownloadingBlocklist = true;
    });
    _spinController.repeat();

    final success = await DnsBlockService.instance.downloadList(level);
    // DnsBlockService fires a change listener that re-pushes domains to the
    // native interceptor; we only need to (re)attach webviews. Done whether
    // or not this screen is still open: leaving it mid-download must not
    // leave the webviews on the old list.
    if (success) await WebInterceptNative.attachToWebViews();

    if (mounted) {
      _spinController.stop();
      _spinController.reset();
      setState(() {
        _isDownloadingBlocklist = false;
      });

      final loc = AppLocalizations.of(context);
      if (success) {
        await _loadBlocklistState();
        if (!mounted) return;
        final domainCount = DnsBlockService.instance.domainCount;
        final message = level == 0
            ? loc.appSettingsDnsBlocklistDisabled
            : loc.appSettingsDnsBlocklistUpdated(
                formatSettingsCount(domainCount));
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

  Future<void> _loadOsmTileUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = readPrefAs<String>(prefs, 'osmTileUrl') ??
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
    if (_isDownloadingRules) return;
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
        if (!mounted) return;
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

  Future<void> _loadFirefoxAutoRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _firefoxAutoRefresh =
          readPrefAs<bool>(prefs, kFirefoxUaAutoRefreshKey) ?? false;
    });
  }

  Future<void> _setFirefoxAutoRefresh(bool value) async {
    setState(() {
      _firefoxAutoRefresh = value;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kFirefoxUaAutoRefreshKey, value);
    // Enabling is itself the user gesture: run the first check right away
    // instead of waiting for the next startup.
    if (value && !_isUpdatingFirefoxVersion) {
      await _updateFirefoxVersion();
    }
  }

  Future<void> _updateFirefoxVersion() async {
    if (_isUpdatingFirefoxVersion) return;
    setState(() {
      _isUpdatingFirefoxVersion = true;
    });

    final result = await FirefoxUserAgentService.instance.refresh();

    if (mounted) {
      setState(() {
        _isUpdatingFirefoxVersion = false;
      });
      final loc = AppLocalizations.of(context);
      final version = FirefoxUserAgentService.instance.majorVersion;
      final message = switch (result) {
        FirefoxVersionRefreshResult.updated =>
          loc.appSettingsFirefoxVersionUpdated(version),
        FirefoxVersionRefreshResult.unchanged =>
          loc.appSettingsFirefoxVersionUnchanged(version),
        FirefoxVersionRefreshResult.failed =>
          loc.appSettingsFirefoxVersionFailed,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
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
    if (_isDownloadingLocalCdn || _isClearingLocalCdn) return;
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
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsLocalCdnDownloaded(downloaded))),
      );
    }
  }

  Future<void> _clearLocalCdnCache() async {
    if (_isDownloadingLocalCdn || _isClearingLocalCdn) return;
    setState(() {
      _isClearingLocalCdn = true;
    });

    await LocalCdnService.instance.clearCache();

    if (mounted) {
      setState(() {
        _isClearingLocalCdn = false;
      });
      await _loadLocalCdnState();
      if (!mounted) return;
      final loc = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(loc.appSettingsLocalCdnCacheCleared)),
      );
    }
  }

  Future<void> _openContentBlocker() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ContentBlockerSettingsScreen(
          onTrustUboHosts: widget.onTrustUboHosts,
        ),
      ),
    );
    // The row names the lists that are on.
    if (mounted) setState(() {});
  }

  String _updatedAt(AppLocalizations loc, DateTime at) =>
      loc.appSettingsUpdatedAt(at.toLocal().toString().split('.')[0]);

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    final enabledLists = [
      for (final list in ContentBlockerService.instance.lists)
        if (list.enabled) list.name,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsPrivacy)),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(loc.blockStatsTitle),
            subtitle: Text(loc.appSettingsProtectionReportSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => guardedOpen(() => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        BlockStatsScreen(siteNames: widget.siteNames),
                  ),
                )),
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
          SettingsGroupHeader(loc.privacyGroupTrackers),
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.siteSettingsHttpsUpgrade)),
                HintButton(
                  title: loc.siteSettingsHttpsUpgrade,
                  description: loc.siteSettingsHttpsUpgradeHint,
                ),
              ],
            ),
            value: _httpsUpgradeEnabled,
            onChanged: (value) {
              setState(() {
                _httpsUpgradeEnabled = value;
              });
              widget.onHttpsUpgradeEnabledChanged(value);
            },
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: Row(
              children: [
                Flexible(child: Text(loc.appSettingsClearUrlsRules)),
                HintButton(
                  title: loc.appSettingsClearUrlsRules,
                  description: loc.appSettingsClearUrlsHint,
                ),
              ],
            ),
            subtitle: Text(
              _rulesLastUpdated != null
                  ? _updatedAt(loc, _rulesLastUpdated!)
                  : loc.appSettingsNotDownloaded,
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
                        ? loc.appSettingsUpdateRules
                        : loc.appSettingsDownloadRules,
                    onPressed: _downloadRules,
                  ),
          ),
          ListTile(
            leading: const Icon(Icons.shield),
            title: Row(
              children: [
                Flexible(child: Text(loc.appSettingsDnsBlocklist)),
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
                          formatSettingsCount(
                              DnsBlockService.instance.domainCount))
                      : loc.appSettingsNotConfigured,
                ),
                if (_blocklistLastUpdated != null)
                  Text(
                    _updatedAt(loc, _blocklistLastUpdated!),
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
                      _dnsBlockSliderValue != _dnsBlockLevel
                          ? Icons.download
                          : Icons.sync,
                    ),
                    tooltip: _dnsBlockSliderValue != _dnsBlockLevel
                        ? loc.appSettingsDownloadBlocklist
                        : loc.appSettingsRefreshBlocklist,
                    onPressed: _downloadBlocklist,
                  ),
          ),
          LevelSlider(
            labels: dnsBlockLevelNames,
            value: _dnsBlockSliderValue,
            onChanged: _isDownloadingBlocklist
                ? null
                : (value) => setState(() => _dnsBlockSliderValue = value),
          ),
          ListTile(
            leading: const Icon(Icons.filter_list),
            title: Row(
              children: [
                Flexible(child: Text(loc.appSettingsContentBlocker)),
                HintButton(
                  title: loc.appSettingsContentBlocker,
                  description: loc.appSettingsContentBlockerHint,
                ),
              ],
            ),
            subtitle: Text(summariseSettings(loc, enabledLists,
                none: loc.appSettingsNotConfigured)),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => guardedOpen(_openContentBlocker),
          ),
          // LocalCDN (Android only)
          if (hostIsAndroid)
            ListTile(
              leading: const Icon(Icons.storage),
              title: Row(
                children: [
                  Flexible(child: Text(loc.appSettingsLocalCdn)),
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
                    Text(
                      _updatedAt(loc, _localCdnLastUpdated!),
                      style: const TextStyle(fontSize: 12),
                    ),
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
          SettingsGroupHeader(loc.appSettingsGroupWhatSitesLearn),
          FirefoxVersionTile(
            majorVersion: FirefoxUserAgentService.instance.majorVersion,
            lastChecked: FirefoxUserAgentService.instance.lastChecked,
            isUpdating: _isUpdatingFirefoxVersion,
            autoUpdate: _firefoxAutoRefresh,
            onUpdate: _updateFirefoxVersion,
            onAutoUpdateChanged: _setFirefoxAutoRefresh,
          ),
          // Timezone polygon dataset — opt-in download enabling the
          // "From picked location" timezone option in per-site settings.
          // Modeled on the DNS blocklist pattern: status + download/refresh
          // button, plus a clear button when data is present.
          ListTile(
            leading: const Icon(Icons.public),
            title: Row(
              children: [
                Flexible(child: Text(loc.appSettingsTimezonePolygons)),
                HintButton(
                  title: loc.appSettingsTimezonePolygons,
                  description: loc.appSettingsTimezonePolygonsHint,
                ),
              ],
            ),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_timezonesCached)
                  Text(loc.appSettingsNotDownloaded)
                else if (_timezoneZoneCount != null)
                  Text(loc.appSettingsZonesCount(
                      formatSettingsCount(_timezoneZoneCount!))),
                if (_timezonesCached && _timezonesLastUpdated != null)
                  Text(
                    _updatedAt(loc, _timezonesLastUpdated!),
                    style: const TextStyle(fontSize: 12),
                  ),
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
                      if (_timezonesCached)
                        IconButton(
                          icon: const Icon(Icons.delete_outline),
                          tooltip: loc.appSettingsClearDataset,
                          onPressed: TimezoneLocationService.instance.clear,
                        ),
                      IconButton(
                        icon: Icon(_timezonesCached
                            ? Icons.sync
                            : Icons.download),
                        tooltip: _timezonesCached
                            ? loc.appSettingsRefreshDataset
                            : loc.appSettingsDownloadDataset,
                        onPressed: _downloadTimezones,
                      ),
                    ],
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    loc.appSettingsLocationPicker,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
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
          if (ScreenCaptureGuard.isSupported) ...[
            SettingsGroupHeader(loc.privacyGroupScreenCapture),
            SwitchListTile(
              secondary: const Icon(Icons.no_photography_outlined),
              title: Row(
                children: [
                  Flexible(child: Text(loc.siteSettingsBlockScreenshots)),
                  HintButton(
                    title: loc.siteSettingsBlockScreenshots,
                    description: loc.appSettingsBlockScreenshotsHint,
                  ),
                ],
              ),
              value: _blockScreenshots,
              onChanged: (value) {
                setState(() {
                  _blockScreenshots = value;
                });
                widget.onBlockScreenshotsChanged?.call(value);
              },
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
