import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import 'package:webspace/web_view_model.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/hint_button.dart';
import 'package:webspace/widgets/root_messenger.dart';

// Supported languages for webview
const List<MapEntry<String?, String>> _languages = [
  MapEntry(null, 'System default'),
  MapEntry('en', 'English'),
  MapEntry('es', 'Español'),
  MapEntry('fr', 'Français'),
  MapEntry('de', 'Deutsch'),
  MapEntry('it', 'Italiano'),
  MapEntry('pt', 'Português'),
  MapEntry('pl', 'Polski'),
  MapEntry('uk', 'Українська'),
  MapEntry('cs', 'Čeština'),
  MapEntry('nl', 'Nederlands'),
  MapEntry('sv', 'Svenska'),
  MapEntry('no', 'Norsk'),
  MapEntry('da', 'Dansk'),
  MapEntry('fi', 'Suomi'),
  MapEntry('et', 'Eesti'),
  MapEntry('lv', 'Latviešu'),
  MapEntry('lt', 'Lietuvių'),
  MapEntry('el', 'Ελληνικά'),
  MapEntry('ro', 'Română'),
  MapEntry('hu', 'Magyar'),
  MapEntry('tr', 'Türkçe'),
  MapEntry('zh-CN', '中文 (简体)'),
  MapEntry('zh-TW', '中文 (繁體)'),
  MapEntry('ja', '日本語'),
  MapEntry('ko', '한국어'),
  MapEntry('ar', 'العربية'),
  MapEntry('he', 'עברית'),
  MapEntry('hi', 'हिन्दी'),
];

String generateRandomUserAgent() {
  // You can modify these values to add more variety to the generated user-agent strings
  List<String> platforms = [
    'Windows NT 10.0; Win64; x64',
    'Macintosh; Intel Mac OS X 10_15_7',
    'Linux x86_64',
    'iPhone; CPU iPhone OS 15_7_3 like Mac OS X',
    'Android 16; Mobile', // Add an Android platform
  ];

  String geckoVersion = '147.0';
  String geckoTrail = '20100101';
  String appName = 'Firefox';
  String appVersion = '147.0';

  String platform = platforms[Random().nextInt(platforms.length)];
  return 'Mozilla/5.0 ($platform; rv:$geckoVersion) Gecko/$geckoTrail $appName/$appVersion';
}

class SettingsScreen extends StatefulWidget {
  final WebViewModel webViewModel;
  /// Callback to sync proxy settings across all WebViewModels
  final void Function(UserProxySettings)? onProxySettingsChanged;
  /// Callback when settings are saved (to trigger webview reload)
  final VoidCallback? onSettingsSaved;
  /// Callback to clear cookies for this site
  final VoidCallback? onClearCookies;
  /// Global user scripts shared across all sites
  final List<UserScriptConfig> globalUserScripts;
  /// Callback when global user scripts are changed
  final void Function(List<UserScriptConfig>)? onGlobalUserScriptsChanged;
  /// Fired when the user toggles / edits / adds / deletes / opts in to a
  /// user script. Parent should dispose this site's webview so the next
  /// render recreates it with the updated [initialUserScripts].
  final VoidCallback? onScriptsChanged;
  final bool useContainers;

  SettingsScreen({
    required this.webViewModel,
    this.onProxySettingsChanged,
    this.onSettingsSaved,
    this.onClearCookies,
    this.globalUserScripts = const [],
    this.onGlobalUserScriptsChanged,
    this.onScriptsChanged,
    this.useContainers = false,
  });

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserProxySettings _proxySettings;
  late TextEditingController _userAgentController;
  late TextEditingController _proxyAddressController;
  late TextEditingController _proxyUsernameController;
  late TextEditingController _proxyPasswordController;
  late bool _javascriptEnabled;
  late bool _thirdPartyCookiesEnabled;
  late bool _incognito;
  late bool _clearUrlEnabled;
  late bool _dnsBlockEnabled;
  late bool _contentBlockEnabled;
  late bool _localCdnEnabled;
  late bool _blockAutoRedirects;
  late bool _fullscreenMode;
  late bool _notificationsEnabled;
  late bool _backgroundPoll;
  String? _selectedLanguage;
  bool _obscureProxyPassword = true;
  bool _showProxyCredentials = false;
  late TextEditingController _latitudeController;
  late TextEditingController _longitudeController;
  late TextEditingController _accuracyController;
  String? _spoofTimezone;
  bool _spoofTimezoneFromLocation = false;
  // Tracks the "live" geolocation mode. Mutually exclusive with static
  // coordinates: enabling live clears coords; picking coords clears live.
  bool _isLiveLocation = false;
  late WebRtcPolicy _webRtcPolicy;

  String getResetUserAgent() {
    return (widget.webViewModel.userAgent == '') ? (widget.webViewModel.defaultUserAgent ?? '') : widget.webViewModel.userAgent;
  }

  @override
  void initState() {
    super.initState();
    // Force DEFAULT proxy on unsupported platforms
    _proxySettings = UserProxySettings(
      type: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.type
          : ProxyType.DEFAULT,
      address: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.address
          : null,
      username: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.username
          : null,
      password: PlatformInfo.isProxySupported
          ? widget.webViewModel.proxySettings.password
          : null,
    );
    _userAgentController = TextEditingController(
      text: getResetUserAgent(),
    );
    _proxyAddressController = TextEditingController(
      text: _proxySettings.address ?? '',
    );
    _proxyUsernameController = TextEditingController(
      text: _proxySettings.username ?? '',
    );
    _proxyPasswordController = TextEditingController(
      text: _proxySettings.password ?? '',
    );
    _javascriptEnabled = widget.webViewModel.javascriptEnabled;
    _thirdPartyCookiesEnabled = widget.webViewModel.thirdPartyCookiesEnabled;
    _incognito = widget.webViewModel.incognito;
    _clearUrlEnabled = widget.webViewModel.clearUrlEnabled;
    _dnsBlockEnabled = widget.webViewModel.dnsBlockEnabled;
    _contentBlockEnabled = widget.webViewModel.contentBlockEnabled;
    _localCdnEnabled = widget.webViewModel.localCdnEnabled;
    _blockAutoRedirects = widget.webViewModel.blockAutoRedirects;
    _fullscreenMode = widget.webViewModel.fullscreenMode;
    _notificationsEnabled = widget.webViewModel.notificationsEnabled;
    _backgroundPoll = widget.webViewModel.backgroundPoll;
    _selectedLanguage = widget.webViewModel.language;
    // locationMode is derived from whether coords are present at save time;
    // no separate UI state needed (see _buildLocationTile).
    _latitudeController = TextEditingController(
      text: widget.webViewModel.spoofLatitude?.toString() ?? '',
    );
    _longitudeController = TextEditingController(
      text: widget.webViewModel.spoofLongitude?.toString() ?? '',
    );
    _accuracyController = TextEditingController(
      text: widget.webViewModel.spoofAccuracy.toString(),
    );
    _spoofTimezone = widget.webViewModel.spoofTimezone;
    _spoofTimezoneFromLocation = widget.webViewModel.spoofTimezoneFromLocation;
    _isLiveLocation = widget.webViewModel.locationMode == LocationMode.live;
    _webRtcPolicy = widget.webViewModel.webRtcPolicy;
    // Show credentials section if credentials already exist
    _showProxyCredentials = _proxySettings.hasCredentials;
  }

  @override
  void dispose() {
    _userAgentController.dispose();
    _proxyAddressController.dispose();
    _proxyUsernameController.dispose();
    _proxyPasswordController.dispose();
    _latitudeController.dispose();
    _longitudeController.dispose();
    _accuracyController.dispose();
    super.dispose();
  }

  String? _validateProxyAddress(String? value) {
    if (_proxySettings.type == ProxyType.DEFAULT) {
      return null;
    }
    
    if (value == null || value.isEmpty) {
      return 'Proxy address is required';
    }
    
    final parts = value.split(':');
    if (parts.length != 2) {
      return 'Format: host:port (e.g., proxy.example.com:1080)';
    }
    
    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) {
      return 'Invalid port number (1-65535)';
    }
    
    return null;
  }

  String _userScriptsSubtitle() {
    final siteCount = widget.webViewModel.userScripts.where((s) => s.enabled).length;
    final enabledIds = widget.webViewModel.enabledGlobalScriptIds;
    final globalCount = widget.globalUserScripts
        .where((s) => enabledIds.contains(s.id))
        .length;
    final parts = <String>[];
    if (siteCount > 0) parts.add('$siteCount site');
    if (globalCount > 0) parts.add('$globalCount global');
    return parts.isEmpty ? 'None' : '${parts.join(', ')} active';
  }

  Widget _buildDnsStatsCard() {
    final stats = DnsBlockService.instance.statsForSite(widget.webViewModel.siteId);
    if (stats.total == 0) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _buildDnsStatChip('${stats.total}', 'total', Colors.blue),
          const SizedBox(width: 6),
          _buildDnsStatChip('${stats.allowed}', 'allowed', Colors.green),
          const SizedBox(width: 6),
          _buildDnsStatChip('${stats.blocked}', 'blocked', Colors.red),
          const SizedBox(width: 6),
          _buildDnsStatChip('${stats.blockRate.toStringAsFixed(1)}%', 'blocked', Colors.orange),
        ],
      ),
    );
  }

  Widget _buildDnsStatChip(String value, String label, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withAlpha(20),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withAlpha(50)),
        ),
        child: Column(
          children: [
            Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
            Text(label, style: TextStyle(fontSize: 9, color: color.withAlpha(180))),
          ],
        ),
      ),
    );
  }

  Future<void> _saveSettings() async {
    // Only validate and update proxy settings on supported platforms
    if (PlatformInfo.isProxySupported) {
      // Validate proxy address if needed
      final proxyError = _validateProxyAddress(_proxyAddressController.text);
      if (proxyError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Proxy Error: $proxyError')),
        );
        return;
      }
    }

    try {
      // Update proxy settings only on supported platforms
      if (PlatformInfo.isProxySupported) {
        _proxySettings.address = _proxyAddressController.text.isEmpty
            ? null
            : _proxyAddressController.text;
        // Only save credentials if the checkbox is enabled
        if (_showProxyCredentials) {
          _proxySettings.username = _proxyUsernameController.text.isEmpty
              ? null
              : _proxyUsernameController.text;
          _proxySettings.password = _proxyPasswordController.text.isEmpty
              ? null
              : _proxyPasswordController.text;
        } else {
          _proxySettings.username = null;
          _proxySettings.password = null;
        }

        widget.webViewModel.proxySettings = _proxySettings;
        LogService.instance.log(
          'Proxy',
          'Saving per-site proxy for siteId=${widget.webViewModel.siteId}: '
              '${_proxySettings.describeForLogs()}',
          level: LogLevel.info,
        );

        // Apply proxy settings immediately
        await widget.webViewModel.updateProxySettings(_proxySettings);

        // On Android, `inapp.ProxyController` is a process-wide singleton:
        // changing the proxy on one site silently changes it for every
        // currently-loaded WebView, so the data model is sync'd to match.
        // On iOS 17+ / macOS 14+, each site has its own
        // `WKWebsiteDataStore.proxyConfigurations`, so per-site values
        // are independent and the sync would clobber them. See PROXY-008.
        if (Platform.isAndroid) {
          LogService.instance.log(
            'Proxy',
            'Android: mirroring per-site proxy across all loaded models '
                '(ProxyController is process-wide)',
          );
          widget.onProxySettingsChanged?.call(_proxySettings);
        }
      } else {
        // Force DEFAULT proxy on unsupported platforms
        final defaultProxy = UserProxySettings(type: ProxyType.DEFAULT);
        widget.webViewModel.proxySettings = defaultProxy;
        LogService.instance.log(
          'Proxy',
          'Per-site proxy unsupported on this platform; forcing DEFAULT for '
              'siteId=${widget.webViewModel.siteId}',
        );
        await widget.webViewModel.updateProxySettings(defaultProxy);
      }

      // Update other settings
      if (_userAgentController.text != '') {
        widget.webViewModel.userAgent = _userAgentController.text;
      }
      widget.webViewModel.javascriptEnabled = _javascriptEnabled;
      widget.webViewModel.thirdPartyCookiesEnabled = _thirdPartyCookiesEnabled;
      widget.webViewModel.incognito = _incognito;
      widget.webViewModel.clearUrlEnabled = _clearUrlEnabled;
      widget.webViewModel.dnsBlockEnabled = _dnsBlockEnabled;
      widget.webViewModel.contentBlockEnabled = _contentBlockEnabled;
      widget.webViewModel.localCdnEnabled = _localCdnEnabled;
      widget.webViewModel.blockAutoRedirects = _blockAutoRedirects;
      widget.webViewModel.fullscreenMode = _fullscreenMode;
      widget.webViewModel.notificationsEnabled = _notificationsEnabled;
      widget.webViewModel.backgroundPoll = _backgroundPoll;
      widget.webViewModel.language = _selectedLanguage;
      // locationMode is derived from the UI state:
      // - `_isLiveLocation` → live (real device GPS forwarded through the shim)
      // - else if custom coords are set → spoof (static custom coords)
      // - else → off (no shim)
      // Live and custom-coords are mutually exclusive in the UI: the user
      // picks one or the other, not both. See _buildLocationTile.
      final lat = double.tryParse(_latitudeController.text.trim());
      final lng = double.tryParse(_longitudeController.text.trim());
      if (_isLiveLocation) {
        widget.webViewModel.locationMode = LocationMode.live;
        widget.webViewModel.spoofLatitude = null;
        widget.webViewModel.spoofLongitude = null;
      } else if (lat != null && lng != null) {
        widget.webViewModel.locationMode = LocationMode.spoof;
        widget.webViewModel.spoofLatitude = lat;
        widget.webViewModel.spoofLongitude = lng;
      } else {
        widget.webViewModel.locationMode = LocationMode.off;
        widget.webViewModel.spoofLatitude = null;
        widget.webViewModel.spoofLongitude = null;
      }
      final accuracy = double.tryParse(_accuracyController.text.trim());
      if (accuracy != null && accuracy > 0) {
        widget.webViewModel.spoofAccuracy = accuracy;
      }
      widget.webViewModel.spoofTimezone = _spoofTimezone;
      widget.webViewModel.spoofTimezoneFromLocation =
          _spoofTimezoneFromLocation;
      widget.webViewModel.webRtcPolicy = _webRtcPolicy;

      if (!mounted) return;

      // Store current URL before disposing webview
      final currentUrl = widget.webViewModel.currentUrl;

      // Dispose the webview so it gets recreated with new settings
      widget.webViewModel.disposeWebView();

      // Update current URL to ensure reload
      widget.webViewModel.currentUrl = currentUrl;

      // Pop first so the Settings route leaves the tree before the parent
      // rebuilds. Notifying the parent inline would mark the Navigator dirty
      // while it is locked during the pop, tripping the '!_debugLocked'
      // assertion in NavigatorState.build.
      Navigator.pop(context);

      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Settings saved and webview reloaded')),
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSettingsSaved?.call();
      });
    } catch (e) {
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text('Error saving settings: $e')),
      );
    }
  }

  Future<void> _openLocationPicker() async {
    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLatitude: double.tryParse(_latitudeController.text.trim()),
          initialLongitude: double.tryParse(_longitudeController.text.trim()),
          initialAccuracy: double.tryParse(_accuracyController.text.trim()) ?? 50.0,
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() {
      _latitudeController.text = result.latitude.toStringAsFixed(6);
      _longitudeController.text = result.longitude.toStringAsFixed(6);
      _accuracyController.text = result.accuracy.toString();
    });
  }

  /// Build the geolocation section. A SegmentedButton at the top (Off /
  /// Static / Live) is always visible so all three modes are reachable
  /// regardless of current state — the previous trailing-button layout
  /// hid Live once coords were set, leaving no way to switch from
  /// static-coords mode to live without clearing coords first.
  ///
  /// Below the selector a detail row shows whatever's relevant for the
  /// active mode: nothing for Off, coords + edit/clear for Static,
  /// "tracking device GPS" for Live.
  ///
  /// `locationMode` is derived from this state at save time, not stored
  /// explicitly here. See [_saveSettings].
  Widget _buildLocationTile() {
    final lat = double.tryParse(_latitudeController.text.trim());
    final lng = double.tryParse(_longitudeController.text.trim());
    final hasCoords = lat != null && lng != null;
    final acc = double.tryParse(_accuracyController.text.trim()) ?? 50.0;

    const hint = HintButton(
      title: 'Geolocation',
      description:
          'Off (default): navigator.geolocation is left untouched. Sites '
          'get the platform default (typically denied unless the user '
          'grants permission to the webview).\n\n'
          'Static: navigator.geolocation returns the coordinates you '
          'supply. Tap "Pick location" to open the picker, where you can '
          'type coordinates, pick on a map, or use the "Use current '
          'location" button to fill them with your real device GPS once. '
          'The coordinates are then static.\n\n'
          'Live: navigator.geolocation calls back into the app on every '
          'getCurrentPosition / watchPosition to fetch a fresh fix from '
          'the platform\'s native location service, so the reported '
          'position tracks the device as it moves. The shim still '
          'overrides Geolocation.prototype and hides the patch from '
          'Function.prototype.toString — so timezone override and WebRTC '
          'policy still apply, but the coordinates are real and current.',
    );

    // Derive the active segment from current state. `Static` is selected
    // when there are coords AND we're not in live mode; `Live` is selected
    // when the live flag is on (regardless of whether stale coords linger
    // — they're ignored on save in that branch).
    final _LocationSegment selected = _isLiveLocation
        ? _LocationSegment.live
        : (hasCoords ? _LocationSegment.staticCoords : _LocationSegment.off);

    void onSegmentChanged(Set<_LocationSegment> values) {
      final v = values.first;
      setState(() {
        switch (v) {
          case _LocationSegment.off:
            _isLiveLocation = false;
            _latitudeController.clear();
            _longitudeController.clear();
            _accuracyController.text = '50';
            break;
          case _LocationSegment.staticCoords:
            _isLiveLocation = false;
            // If switching from off → static with no coords yet, open the
            // picker so the user lands on something useful instead of
            // an empty selection. From live → static we keep whatever
            // coords were last saved (probably none) and the picker is
            // one tap away on the detail row.
            if (!hasCoords) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _openLocationPicker();
              });
            }
            break;
          case _LocationSegment.live:
            _isLiveLocation = true;
            break;
        }
      });
    }

    final selector = SegmentedButton<_LocationSegment>(
      segments: const [
        ButtonSegment(
            value: _LocationSegment.off,
            icon: Icon(Icons.location_disabled),
            label: Text('Off')),
        ButtonSegment(
            value: _LocationSegment.staticCoords,
            icon: Icon(Icons.map_outlined),
            label: Text('Static')),
        ButtonSegment(
            value: _LocationSegment.live,
            icon: Icon(Icons.my_location),
            label: Text('Live')),
      ],
      selected: {selected},
      onSelectionChanged: onSegmentChanged,
      showSelectedIcon: false,
    );

    Widget detail;
    switch (selected) {
      case _LocationSegment.off:
        detail = const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Sites use the webview default (typically denied).',
            style: TextStyle(fontSize: 12),
          ),
        );
        break;
      case _LocationSegment.live:
        detail = const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Tracks the device\'s real GPS via the platform location '
            'service. Permission is requested on the first call.',
            style: TextStyle(fontSize: 12),
          ),
        );
        break;
      case _LocationSegment.staticCoords:
        if (hasCoords) {
          detail = ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(
              '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}  '
              '±${acc.toStringAsFixed(0)}m',
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Edit location',
                  icon: const Icon(Icons.edit_location_alt_outlined),
                  onPressed: _openLocationPicker,
                ),
                IconButton(
                  tooltip: 'Clear custom location',
                  icon: const Icon(Icons.close),
                  onPressed: () => setState(() {
                    _latitudeController.clear();
                    _longitudeController.clear();
                    _accuracyController.text = '50';
                  }),
                ),
              ],
            ),
          );
        } else {
          detail = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Expanded(child: Text(
                  'No custom location set',
                  style: TextStyle(fontSize: 12),
                )),
                OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('Pick'),
                  onPressed: _openLocationPicker,
                ),
              ],
            ),
          );
        }
        break;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(
            children: const [
              Text('Geolocation',
                  style: TextStyle(fontWeight: FontWeight.w500)),
              hint,
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SizedBox(
            // SegmentedButton wants a constrained width; give it the full
            // row so the three pills don't crowd into a corner on tablets.
            width: double.infinity,
            child: selector,
          ),
        ),
        detail,
      ],
    );
  }

  /// Sentinel value used in the timezone dropdown for the "From picked
  /// location" entry. Not a real IANA name — translated to/from the
  /// `spoofTimezoneFromLocation` bool when reading and writing.
  static const String _kFromLocationSentinel = '__from_location__';

  Widget _buildTimezoneDropdown() {
    final tzReady = TimezoneLocationService.instance.isReady;
    final lat = double.tryParse(_latitudeController.text.trim());
    final lng = double.tryParse(_longitudeController.text.trim());
    final hasCoords = lat != null && lng != null;
    // Preview what the dataset would resolve to right now, so the user can
    // see whether the lookup will succeed for their picked coords. Falls
    // back to a hint if either prerequisite is missing.
    final preview = (tzReady && hasCoords)
        ? (TimezoneLocationService.instance.lookup(lat, lng) ??
            'no match — fall through to system default')
        : (!tzReady
            ? 'Download polygon dataset in App Settings'
            : 'Pick a location first');

    final value = _spoofTimezoneFromLocation
        ? _kFromLocationSentinel
        : (commonTimezones.any((e) => e.key == _spoofTimezone)
            ? _spoofTimezone
            : null);

    // The "From picked location" entry is conceptually a sibling of
    // "System default" (both auto-derive the timezone instead of taking
    // an explicit value), so insert it right after the System default
    // entry rather than at the bottom of the list.
    final items = <DropdownMenuItem<String?>>[];
    var insertedFromLocation = false;
    for (final e in commonTimezones) {
      items.add(DropdownMenuItem<String?>(
        value: e.key,
        child: Text(_timezoneLabel(e)),
      ));
      if (!insertedFromLocation && e.key == null) {
        items.add(DropdownMenuItem<String?>(
          value: _kFromLocationSentinel,
          child: Text('From picked location ($preview)'),
        ));
        insertedFromLocation = true;
      }
    }
    // Defensive fallback: if commonTimezones ever loses the System
    // default entry, still expose the option somewhere.
    if (!insertedFromLocation) {
      items.insert(0, DropdownMenuItem<String?>(
        value: _kFromLocationSentinel,
        child: Text('From picked location ($preview)'),
      ));
    }

    return DropdownButtonFormField<String?>(
      value: value,
      decoration: const InputDecoration(
        labelText: 'Timezone',
        helperText: 'Overrides Intl.DateTimeFormat and Date getters',
        border: OutlineInputBorder(),
      ),
      items: items,
      isExpanded: true,
      onChanged: (v) => setState(() {
        if (v == _kFromLocationSentinel) {
          _spoofTimezoneFromLocation = true;
          _spoofTimezone = null;
        } else {
          _spoofTimezoneFromLocation = false;
          _spoofTimezone = v;
        }
      }),
    );
  }

  /// Render a timezone dropdown entry. The `null` (System default) entry is
  /// enriched with the device's current timezone abbreviation/offset and the
  /// current local time, so the user can see what "default" actually entails.
  String _timezoneLabel(MapEntry<String?, String> entry) {
    if (entry.key != null) return entry.value;
    final now = DateTime.now();
    final tzName = now.timeZoneName;
    final offset = now.timeZoneOffset;
    final sign = offset.isNegative ? '-' : '+';
    final hours = offset.inHours.abs().toString().padLeft(2, '0');
    final mins = (offset.inMinutes.abs() % 60).toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return '${entry.value} ($tzName, UTC$sign$hours:$mins, $hh:$mm)';
  }

  List<Widget> _buildLocationSection() {
    return [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text('Location & timezone',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      _buildLocationTile(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: _buildTimezoneDropdown(),
      ),
      ListTile(
        title: Row(
          children: const [
            Flexible(child: Text('WebRTC policy')),
            HintButton(
              title: 'WebRTC leak protection',
              description:
                  'HTTP(S) and SOCKS5 proxies only carry TCP. WebRTC uses UDP '
                  'and leaks your real IP around the proxy. '
                  '"Relay only" forces iceTransportPolicy=relay and strips '
                  'non-relay ICE candidates; video calls that rely on direct '
                  'peer-to-peer connections will break. '
                  '"Disabled" blocks RTCPeerConnection entirely.',
            ),
          ],
        ),
        trailing: DropdownButton<WebRtcPolicy>(
          value: _webRtcPolicy,
          onChanged: (v) {
            if (v != null) setState(() => _webRtcPolicy = v);
          },
          items: const [
            DropdownMenuItem(
                value: WebRtcPolicy.defaultPolicy, child: Text('Default')),
            DropdownMenuItem(
                value: WebRtcPolicy.relayOnly, child: Text('Relay only')),
            DropdownMenuItem(
                value: WebRtcPolicy.disabled, child: Text('Disabled')),
          ],
        ),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Settings')),
      body: ListView(
        children: [
          // Only show proxy settings on supported platforms
          if (PlatformInfo.isProxySupported) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'Proxy settings are shared across all sites.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            ListTile(
              title: Text('Proxy Type'),
              trailing: DropdownButton<ProxyType>(
                value: _proxySettings.type,
                onChanged: (ProxyType? newValue) {
                  if (newValue != null) {
                    setState(() {
                      _proxySettings.type = newValue;
                    });
                  }
                },
                items: ProxyType.values.map<DropdownMenuItem<ProxyType>>(
                  (ProxyType value) {
                    return DropdownMenuItem<ProxyType>(
                      value: value,
                      child: Text(value.toString().split('.').last),
                    );
                  },
                ).toList(),
              ),
            ),
            if (_proxySettings.type != ProxyType.DEFAULT) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                child: TextFormField(
                  controller: _proxyAddressController,
                  decoration: InputDecoration(
                    labelText: 'Proxy Address',
                    hintText: 'host:port (e.g., proxy.example.com:1080)',
                    helperText: 'Format: host:port',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateProxyAddress,
                ),
              ),
              CheckboxListTile(
                title: Text('Proxy requires authentication'),
                value: _showProxyCredentials,
                onChanged: (bool? value) {
                  setState(() {
                    _showProxyCredentials = value ?? false;
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
              ),
              if (_showProxyCredentials) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: TextFormField(
                    controller: _proxyUsernameController,
                    decoration: InputDecoration(
                      labelText: 'Proxy Username',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: TextFormField(
                    controller: _proxyPasswordController,
                    obscureText: _obscureProxyPassword,
                    decoration: InputDecoration(
                      labelText: 'Proxy Password',
                      border: OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureProxyPassword ? Icons.visibility : Icons.visibility_off,
                        ),
                        onPressed: () {
                          setState(() {
                            _obscureProxyPassword = !_obscureProxyPassword;
                          });
                        },
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
          SwitchListTile(
            title: Text('JavaScript Enabled'),
            value: _javascriptEnabled,
            onChanged: (bool value) {
              setState(() {
                _javascriptEnabled = value;
              });
            },
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                onPressed: () {
                  setState(() {
                    _userAgentController.text = widget.webViewModel.defaultUserAgent ?? widget.webViewModel.userAgent;
                  });
                },
                icon: Icon(Icons.home), // Use an appropriate icon for generating user-agent
                color: Theme.of(context).colorScheme.primary,
                iconSize: 24, // Adjust the icon size as needed
              ),
              Expanded(
                child: TextFormField(
                  decoration: InputDecoration(labelText: 'User-Agent'),
                  controller: _userAgentController,
                ),
              ),
              SizedBox(width: 8), // Add some spacing between the text field and the button
              IconButton(
                onPressed: () {
                  String newUserAgent = generateRandomUserAgent();
                  setState(() {
                    _userAgentController.text = newUserAgent;
                  });
                },
                icon: Icon(Icons.autorenew), // Use an appropriate icon for generating user-agent
                color: Theme.of(context).colorScheme.primary,
                iconSize: 24, // Adjust the icon size as needed
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: DropdownButtonFormField<String?>(
              value: _selectedLanguage,
              decoration: InputDecoration(
                labelText: 'Language',
                helperText: 'Sets Accept-Language header for HTTP requests',
                border: OutlineInputBorder(),
              ),
              items: _languages.map((entry) {
                return DropdownMenuItem<String?>(
                  value: entry.key,
                  child: Text(entry.value),
                );
              }).toList(),
              onChanged: (String? value) {
                setState(() {
                  _selectedLanguage = value;
                });
              },
            ),
          ),
          SwitchListTile(
            title: const Text('Third-party cookies'),
            value: _thirdPartyCookiesEnabled,
            onChanged: (bool value) {
              setState(() {
                _thirdPartyCookiesEnabled = value;
              });
            },
          ),
          SwitchListTile(
            title: const Text('Incognito mode'),
            subtitle: const Text('No cookies or cache persist'),
            value: _incognito,
            onChanged: (bool value) {
              setState(() {
                _incognito = value;
              });
            },
          ),
          SwitchListTile(
            title: Row(
              children: [
                const Text('ClearURLs'),
                const HintButton(
                  title: 'ClearURLs',
                  description:
                      'Removes tracking parameters (like utm_source, fbclid) from URLs before loading them. '
                      'This helps protect your privacy by preventing sites from tracking where you came from.',
                ),
              ],
            ),
            subtitle: const Text('Strip tracking parameters from URLs'),
            value: _clearUrlEnabled,
            onChanged: (bool value) {
              setState(() {
                _clearUrlEnabled = value;
              });
            },
          ),
          SwitchListTile(
            title: Row(
              children: [
                const Text('DNS Blocklist'),
                const HintButton(
                  title: 'DNS Blocklist',
                  description:
                      'Blocks known advertising, tracking, and malware domains at the DNS level before they can load. '
                      'Uses the Hagezi blocklist with configurable severity levels. '
                      'Configure the blocklist level in App Settings.',
                ),
              ],
            ),
            subtitle: Text(
              DnsBlockService.instance.hasBlocklist
                  ? dnsBlockLevelNames[DnsBlockService.instance.level]
                  : 'Not configured',
            ),
            value: _dnsBlockEnabled,
            onChanged: DnsBlockService.instance.hasBlocklist
                ? (bool value) {
                    setState(() {
                      _dnsBlockEnabled = value;
                    });
                  }
                : null,
          ),
          if (DnsBlockService.instance.hasBlocklist) _buildDnsStatsCard(),
          SwitchListTile(
            title: Row(
              children: [
                const Flexible(child: Text('Content Blocker')),
                const HintButton(
                  title: 'Content Blocker',
                  description:
                      'Blocks ads, trackers, and unwanted content using filter lists (like EasyList). '
                      'Supports domain blocking, CSS cosmetic filters, and text-based hiding rules. '
                      'Manage filter lists in App Settings.',
                ),
              ],
            ),
            subtitle: Text(
              ContentBlockerService.instance.hasRules
                  ? '${ContentBlockerService.instance.totalRuleCount} rules'
                  : 'Not configured',
            ),
            value: _contentBlockEnabled,
            onChanged: ContentBlockerService.instance.hasRules
                ? (bool value) {
                    setState(() {
                      _contentBlockEnabled = value;
                    });
                  }
                : null,
          ),
          ListTile(
            title: const Text('User Scripts'),
            subtitle: Text(
              _userScriptsSubtitle(),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserScriptsScreen(
                    title: 'User Scripts',
                    userScripts: widget.webViewModel.userScripts,
                    onSave: (scripts) {
                      widget.webViewModel.userScripts = scripts;
                    },
                    globalUserScripts: widget.globalUserScripts,
                    onGlobalUserScriptsChanged: widget.onGlobalUserScriptsChanged,
                    enabledGlobalScriptIds: widget.webViewModel.enabledGlobalScriptIds,
                    onEnabledGlobalScriptIdsChanged: (ids) {
                      widget.webViewModel.enabledGlobalScriptIds = ids;
                    },
                    onWebViewReset: widget.onScriptsChanged,
                    // Re-reads the controller each call: changing the
                    // script list disposes and recreates the webview, so
                    // a closure capturing the controller at construction
                    // time would NPE.
                    onRun: (source) async {
                      final controller = widget.webViewModel.controller;
                      if (controller == null) {
                        return '(webview not ready — wait for page to finish loading)';
                      }
                      final logsBefore = widget.webViewModel.consoleLogs.length;
                      await controller.evaluateJavascript(source);
                      // Brief delay to let console messages arrive
                      await Future.delayed(const Duration(milliseconds: 200));
                      final newLogs = widget.webViewModel.consoleLogs.skip(logsBefore);
                      return newLogs.map((e) => e.message).join('\n');
                    },
                  ),
                ),
              );
            },
          ),
          if (Platform.isAndroid)
            SwitchListTile(
              title: Row(
                children: [
                  const Text('LocalCDN'),
                  const HintButton(
                    title: 'LocalCDN',
                    description:
                        'Serves common CDN resources (JavaScript libraries, fonts, CSS frameworks) from a local cache '
                        'instead of fetching them from third-party CDN servers. '
                        'This prevents CDN providers from tracking your browsing activity across sites.',
                  ),
                ],
              ),
              subtitle: Text(
                LocalCdnService.instance.hasCache
                    ? '${LocalCdnService.instance.resourceCount} cached resources'
                    : 'Download the cache in app settings first',
              ),
              value: _localCdnEnabled && LocalCdnService.instance.hasCache,
              onChanged: LocalCdnService.instance.hasCache
                  ? (bool value) {
                      setState(() {
                        _localCdnEnabled = value;
                      });
                    }
                  : null,
            ),
          SwitchListTile(
            title: Row(
              children: [
                const Flexible(child: Text('Block auto-redirects')),
                const HintButton(
                  title: 'Block Auto-Redirects',
                  description:
                      'Prevents scripts from automatically navigating you to a different domain. '
                      'This helps avoid being silently redirected to tracking or advertising pages.',
                ),
              ],
            ),
            subtitle: const Text('Block script-initiated cross-domain navigations'),
            value: _blockAutoRedirects,
            onChanged: (bool value) {
              setState(() {
                _blockAutoRedirects = value;
              });
            },
          ),
          SwitchListTile(
            title: Row(
              children: [
                const Flexible(child: Text('Full screen mode')),
                const HintButton(
                  title: 'Full Screen Mode',
                  description:
                      'Automatically enters full screen when this site is selected. '
                      'Hides the app bar, tab strip, and system UI for an immersive experience. '
                      'Tap the edge of the screen or use the back gesture to exit full screen.',
                ),
              ],
            ),
            subtitle: const Text('Auto-enter full screen for this site'),
            value: _fullscreenMode,
            onChanged: (bool value) {
              setState(() {
                _fullscreenMode = value;
              });
            },
          ),
          if (widget.useContainers)
            SwitchListTile(
              title: const Text('Notifications'),
              subtitle: const Text('Allow this site to show system notifications'),
              value: _notificationsEnabled,
              onChanged: (bool value) {
                setState(() {
                  _notificationsEnabled = value;
                });
              },
            ),
          if (widget.useContainers)
            SwitchListTile(
              title: const Text('Background polling'),
              subtitle: Text(
                Platform.isIOS
                    ? 'Check for updates periodically (~15-30 min while app is closed)'
                    : 'Keep checking for updates while app is backgrounded',
              ),
              value: _backgroundPoll,
              onChanged: (bool value) {
                setState(() {
                  _backgroundPoll = value;
                });
              },
            ),
          ..._buildLocationSection(),
          if (widget.onClearCookies != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: OutlinedButton.icon(
                icon: Icon(Icons.cookie, color: Colors.red),
                label: Text('Clear Cookies', style: TextStyle(color: Colors.red)),
                style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.red)),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text('Clear Cookies'),
                      content: Text('Are you sure you want to clear all cookies for this site?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text('Clear', style: TextStyle(color: Colors.red)),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) {
                    widget.onClearCookies!();
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Cookies cleared')),
                      );
                    }
                  }
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: _saveSettings,
              child: Text('Save Settings'),
            ),
          ),
        ],
      ),
    );
  }
}

/// Three-way segmented control state for the per-site geolocation row.
/// Maps to LocationMode at save time:
///   off    -> LocationMode.off     (no shim)
///   custom -> LocationMode.spoof   (static user-supplied coords)
///   live   -> LocationMode.live    (real device GPS via the shim's
///                                   getRealLocation handler)
enum _LocationSegment { off, staticCoords, live }

