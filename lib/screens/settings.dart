import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/web_view_model.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/screens/site_settings_qr.dart';
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

  String geckoVersion = '151.0';
  String geckoTrail = '20100101';
  String appName = 'Firefox';
  String appVersion = '151.0';

  String platform = platforms[Random().nextInt(platforms.length)];
  return 'Mozilla/5.0 ($platform; rv:$geckoVersion) Gecko/$geckoTrail $appName/$appVersion';
}

class SettingsScreen extends StatefulWidget {
  final WebViewModel webViewModel;
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

  /// Android-only: name of another site whose `notificationsEnabled` is
  /// already on with a conflicting proxy fingerprint, or `null` if there
  /// is no conflict. When non-null, the Notifications toggle renders
  /// disabled with an explanatory subtitle (NOTIF-005-A). On other
  /// platforms or when there's no conflict, this is `null`.
  final String? notificationsBlockedBySite;

  /// Sites OTHER than [webViewModel], used by the domain-claim editor
  /// (LIR-008 task 8.4) for hijack/overlap detection.
  final List<WebViewModel> otherSites;

  SettingsScreen({
    required this.webViewModel,
    this.onSettingsSaved,
    this.onClearCookies,
    this.globalUserScripts = const [],
    this.onGlobalUserScriptsChanged,
    this.onScriptsChanged,
    this.useContainers = false,
    this.notificationsBlockedBySite,
    this.otherSites = const [],
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
  late bool _alwaysOpenHome;
  late bool _clearUrlEnabled;
  late bool _dnsBlockEnabled;
  late bool _contentBlockEnabled;
  late bool _trackingProtectionEnabled;
  late bool _localCdnEnabled;
  late bool _blockAutoRedirects;
  late bool _fullscreenMode;
  late bool _htmlCachingEnabled;
  late bool _notificationsEnabled;
  bool? _protectedContentAllowed;
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
  // Granularity applied to the live fix before the shim surfaces it to
  // the page. Only meaningful when `_isLiveLocation` is true; persists
  // across switches between segments so the user's preference isn't lost
  // when they toggle Off → Live again.
  LocationGranularity _liveLocationGranularity = LocationGranularity.gps;
  // Sticky preference for the "Approximate" sub-switch under the GPS
  // segment. Derived from the granularity on load (true iff approximate)
  // and remembered across GPS↔GSM segment toggles so flipping to GSM
  // and back doesn't silently drop the user's snap preference.
  bool _liveGpsApproximate = false;
  late WebRtcPolicy _webRtcPolicy;

  /// Snapshot of every form field captured after [_loadFromModel] (and again
  /// after a successful save). [_isDirty] compares the live form against
  /// this map to decide whether to prompt before pop. Text-controller
  /// listeners poke setState on every keystroke so [PopScope.canPop] gets
  /// re-evaluated.
  late Map<String, Object?> _initialSnapshot;

  String getResetUserAgent() {
    return (widget.webViewModel.userAgent == '') ? (widget.webViewModel.defaultUserAgent ?? '') : widget.webViewModel.userAgent;
  }

  @override
  void initState() {
    super.initState();
    _userAgentController = TextEditingController();
    _proxyAddressController = TextEditingController();
    _proxyUsernameController = TextEditingController();
    _proxyPasswordController = TextEditingController();
    _latitudeController = TextEditingController();
    _longitudeController = TextEditingController();
    _accuracyController = TextEditingController();
    _loadFromModel();
    _initialSnapshot = _currentSnapshot();
    _userAgentController.addListener(_onAnyFieldChanged);
    _proxyAddressController.addListener(_onAnyFieldChanged);
    _proxyUsernameController.addListener(_onAnyFieldChanged);
    _proxyPasswordController.addListener(_onAnyFieldChanged);
    _latitudeController.addListener(_onAnyFieldChanged);
    _longitudeController.addListener(_onAnyFieldChanged);
    _accuracyController.addListener(_onAnyFieldChanged);
    NotificationService.instance.addPermissionListener(_onPermissionChanged);
  }

  void _onAnyFieldChanged() {
    if (mounted) setState(() {});
  }

  Map<String, Object?> _currentSnapshot() => {
        'proxyType': _proxySettings.type,
        'proxyAddress': _proxyAddressController.text,
        'proxyUsername': _proxyUsernameController.text,
        'proxyPassword': _proxyPasswordController.text,
        'showProxyCredentials': _showProxyCredentials,
        'userAgent': _userAgentController.text,
        'javascriptEnabled': _javascriptEnabled,
        'thirdPartyCookiesEnabled': _thirdPartyCookiesEnabled,
        'incognito': _incognito,
        'alwaysOpenHome': _alwaysOpenHome,
        'clearUrlEnabled': _clearUrlEnabled,
        'dnsBlockEnabled': _dnsBlockEnabled,
        'contentBlockEnabled': _contentBlockEnabled,
        'trackingProtectionEnabled': _trackingProtectionEnabled,
        'localCdnEnabled': _localCdnEnabled,
        'blockAutoRedirects': _blockAutoRedirects,
        'fullscreenMode': _fullscreenMode,
        'htmlCachingEnabled': _htmlCachingEnabled,
        'notificationsEnabled': _notificationsEnabled,
        'protectedContentAllowed': _protectedContentAllowed,
        'selectedLanguage': _selectedLanguage,
        'latitude': _latitudeController.text,
        'longitude': _longitudeController.text,
        'accuracy': _accuracyController.text,
        'spoofTimezone': _spoofTimezone,
        'spoofTimezoneFromLocation': _spoofTimezoneFromLocation,
        'isLiveLocation': _isLiveLocation,
        'liveLocationGranularity': _liveLocationGranularity,
        'webRtcPolicy': _webRtcPolicy,
      };

  bool _isDirty() {
    final cur = _currentSnapshot();
    for (final key in _initialSnapshot.keys) {
      if (cur[key] != _initialSnapshot[key]) return true;
    }
    return false;
  }

  Future<bool> _confirmDiscard() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text(
          'You have unsaved changes to this site\'s settings. '
          'Leaving now will discard them.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Discard',
              style: TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _onPermissionChanged() {
    if (mounted) setState(() {});
  }

  /// Mirror [widget.webViewModel] into the form state. Called from
  /// [initState] and from the apply-from-QR handler after the decoded
  /// payload has been written back into the model.
  void _loadFromModel() {
    final m = widget.webViewModel;
    // Force DEFAULT proxy on unsupported platforms.
    _proxySettings = UserProxySettings(
      type: PlatformInfo.isProxySupported
          ? m.proxySettings.type
          : ProxyType.DEFAULT,
      address: PlatformInfo.isProxySupported ? m.proxySettings.address : null,
      username: PlatformInfo.isProxySupported ? m.proxySettings.username : null,
      password: PlatformInfo.isProxySupported ? m.proxySettings.password : null,
    );
    _userAgentController.text = getResetUserAgent();
    _proxyAddressController.text = _proxySettings.address ?? '';
    _proxyUsernameController.text = _proxySettings.username ?? '';
    _proxyPasswordController.text = _proxySettings.password ?? '';
    _javascriptEnabled = m.javascriptEnabled;
    _thirdPartyCookiesEnabled = m.thirdPartyCookiesEnabled;
    _incognito = m.incognito;
    _alwaysOpenHome = m.alwaysOpenHome;
    _clearUrlEnabled = m.clearUrlEnabled;
    _dnsBlockEnabled = m.dnsBlockEnabled;
    _contentBlockEnabled = m.contentBlockEnabled;
    _trackingProtectionEnabled = m.trackingProtectionEnabled;
    _localCdnEnabled = m.localCdnEnabled;
    _blockAutoRedirects = m.blockAutoRedirects;
    _fullscreenMode = m.fullscreenMode;
    _htmlCachingEnabled = m.htmlCachingEnabled;
    _notificationsEnabled = m.notificationsEnabled;
    _protectedContentAllowed = m.protectedContentAllowed;
    _selectedLanguage = m.language;
    _latitudeController.text = m.spoofLatitude?.toString() ?? '';
    _longitudeController.text = m.spoofLongitude?.toString() ?? '';
    _accuracyController.text = m.spoofAccuracy.toString();
    _spoofTimezone = m.spoofTimezone;
    _spoofTimezoneFromLocation = m.spoofTimezoneFromLocation;
    _isLiveLocation = m.locationMode == LocationMode.live;
    _liveLocationGranularity = m.liveLocationGranularity;
    _liveGpsApproximate =
        m.liveLocationGranularity == LocationGranularity.approximate;
    _webRtcPolicy = m.webRtcPolicy;
    _showProxyCredentials = _proxySettings.hasCredentials;
  }

  @override
  void dispose() {
    NotificationService.instance.removePermissionListener(_onPermissionChanged);
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
          sensitivity: LogSensitivity.sensitive,
        );

        // Apply proxy settings immediately
        await widget.webViewModel.updateProxySettings(_proxySettings);
      } else {
        // Force DEFAULT proxy on unsupported platforms
        final defaultProxy = UserProxySettings(type: ProxyType.DEFAULT);
        widget.webViewModel.proxySettings = defaultProxy;
        LogService.instance.log(
          'Proxy',
          'Per-site proxy unsupported on this platform; forcing DEFAULT for '
              'siteId=${widget.webViewModel.siteId}',
          sensitivity: LogSensitivity.sensitive,
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
      widget.webViewModel.alwaysOpenHome = _alwaysOpenHome;
      widget.webViewModel.clearUrlEnabled = _clearUrlEnabled;
      widget.webViewModel.dnsBlockEnabled = _dnsBlockEnabled;
      widget.webViewModel.contentBlockEnabled = _contentBlockEnabled;
      widget.webViewModel.trackingProtectionEnabled = _trackingProtectionEnabled;
      widget.webViewModel.localCdnEnabled = _localCdnEnabled;
      widget.webViewModel.blockAutoRedirects = _blockAutoRedirects;
      widget.webViewModel.fullscreenMode = _fullscreenMode;
      widget.webViewModel.htmlCachingEnabled = _htmlCachingEnabled;
      widget.webViewModel.notificationsEnabled = _notificationsEnabled;
      widget.webViewModel.protectedContentAllowed = _protectedContentAllowed;
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
      widget.webViewModel.liveLocationGranularity = _liveLocationGranularity;
      widget.webViewModel.webRtcPolicy = _webRtcPolicy;

      if (!mounted) return;

      // Store current URL before disposing webview
      final currentUrl = widget.webViewModel.currentUrl;

      // Dispose the webview so it gets recreated with new settings
      widget.webViewModel.disposeWebView();

      // Update current URL to ensure reload
      widget.webViewModel.currentUrl = currentUrl;

      // Mark the form clean so the PopScope guard (canPop: !_isDirty()) lets
      // this pop through without prompting for discard. Wait one frame so
      // the rebuild commits the new canPop value before we call pop.
      setState(() {
        _initialSnapshot = _currentSnapshot();
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;

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
          'policy still apply, but the coordinates are real and current.\n\n'
          'In Live mode, pick a provider:\n'
          'GPS: real device coordinates via the GPS provider. Use when '
          'the site needs metre-level positioning (turn-by-turn '
          'navigation, AR, hyper-local search).\n'
          'GSM: cell-tower / Wi-Fi positioning only — no GPS chip and '
          'no fine-location permission. Result snapped to a ~1.1 km '
          'grid. Most privacy-respectful but may return nothing on '
          'devices without a Network Location Provider (some de-Googled '
          'phones).\n\n'
          'Under GPS, toggle "Approximate" to have the shim snap the '
          'lat/lng to a ~110 m grid before the page sees it — same '
          'provider speed, fuzzier result. Use when the site needs '
          'your general area but not your exact position (weather, '
          '"stores nearby", traffic).',
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
      segments: [
        const ButtonSegment(
            value: _LocationSegment.off,
            icon: Icon(Icons.location_disabled),
            label: Text('Off')),
        const ButtonSegment(
            value: _LocationSegment.staticCoords,
            icon: Icon(Icons.map_outlined),
            label: Text('Static')),
        const ButtonSegment(
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
        detail = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Tracks the device\'s real GPS via the platform location '
                'service. Permission is requested on the first call.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              // Two-tier picker: GPS vs GSM at the top (provider), with an
              // "Approximate" sub-switch that only applies under GPS — both
              // share the same OS-level provider, the switch just toggles
              // whether the JS shim snaps the result. GSM is a different
              // provider entirely (NETWORK only) and has no sub-toggle.
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<_LiveProvider>(
                  segments: const [
                    ButtonSegment(
                      value: _LiveProvider.gps,
                      icon: Icon(Icons.gps_fixed),
                      label: Text('GPS'),
                    ),
                    ButtonSegment(
                      value: _LiveProvider.gsm,
                      icon: Icon(Icons.cell_tower),
                      label: Text('GSM'),
                    ),
                  ],
                  selected: {
                    _liveLocationGranularity == LocationGranularity.gsm
                        ? _LiveProvider.gsm
                        : _LiveProvider.gps,
                  },
                  onSelectionChanged: (vs) => setState(() {
                    // Preserve the user's approximate preference across
                    // GPS↔GSM segment toggles: when they leave GPS the
                    // saved-approximate hint lives in the local switch
                    // below; coming back to GPS we read its state.
                    if (vs.first == _LiveProvider.gsm) {
                      _liveLocationGranularity = LocationGranularity.gsm;
                    } else {
                      _liveLocationGranularity = _liveGpsApproximate
                          ? LocationGranularity.approximate
                          : LocationGranularity.gps;
                    }
                  }),
                  showSelectedIcon: false,
                ),
              ),
              const SizedBox(height: 4),
              if (_liveLocationGranularity != LocationGranularity.gsm)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('Approximate'),
                  subtitle: const Text(
                    'Snap lat/lng to a ~110 m grid before the page sees it.',
                    style: TextStyle(fontSize: 11),
                  ),
                  value: _liveGpsApproximate,
                  onChanged: (v) => setState(() {
                    _liveGpsApproximate = v;
                    _liveLocationGranularity = v
                        ? LocationGranularity.approximate
                        : LocationGranularity.gps;
                  }),
                ),
              Text(
                switch (_liveLocationGranularity) {
                  LocationGranularity.gps =>
                    'GPS: real device coordinates and accuracy. Use for '
                        'turn-by-turn navigation or hyper-local search.',
                  LocationGranularity.approximate =>
                    'GPS provider, lat/lng snapped to a ~110 m grid '
                        'before the page sees it. Fast and works on '
                        'devices without a network-location backend.',
                  LocationGranularity.gsm =>
                    'GSM: network provider only (cell-tower / Wi-Fi), no '
                        'GPS chip, result snapped to a ~1.1 km grid. May '
                        'fail on devices without an NLP backend.',
                },
                style: const TextStyle(fontSize: 11),
              ),
            ],
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

    // Tracking Protection forces the timezone to "From picked location"
    // when coords are set so the spoofed Date/Intl values match the
    // spoofed geo. With no coords picked the umbrella does NOT touch
    // the timezone — the user's stored choice (or system default) stands.
    final bool forceFromLocation = _trackingProtectionEnabled && hasCoords;
    final String? value = forceFromLocation
        ? _kFromLocationSentinel
        : (_spoofTimezoneFromLocation
            ? _kFromLocationSentinel
            : (commonTimezones.any((e) => e.key == _spoofTimezone)
                ? _spoofTimezone
                : null));

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
      decoration: InputDecoration(
        labelText: 'Timezone',
        helperText: forceFromLocation
            ? 'Forced to "From picked location" by Tracking Protection'
            : 'Overrides Intl.DateTimeFormat and Date getters',
        border: const OutlineInputBorder(),
      ),
      items: items,
      isExpanded: true,
      onChanged: forceFromLocation
          ? null
          : (v) => setState(() {
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
    return PopScope(
      canPop: !_isDirty(),
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        final discard = await _confirmDiscard();
        if (discard != true || !mounted) return;
        setState(() {
          _initialSnapshot = _currentSnapshot();
        });
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted) return;
        navigator.pop();
      },
      child: Scaffold(
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
            title: const Text('Always open Home'),
            subtitle: Text(
              _incognito
                  ? 'Forced on by Incognito'
                  : 'Reset URL on app restart and home-screen shortcut '
                      '(cookies persist)',
            ),
            value: _incognito || _alwaysOpenHome,
            onChanged: _incognito
                ? null
                : (bool value) {
                    setState(() {
                      _alwaysOpenHome = value;
                    });
                  },
          ),
          SwitchListTile(
            title: Row(
              children: [
                const Flexible(child: Text('Tracking Protection')),
                const HintButton(
                  title: 'Tracking Protection',
                  description:
                      'Umbrella per-site Enhanced Tracking Protection. When on, '
                      'forces ClearURLs, DNS Blocklist, and Content Blocker to be '
                      'active for this site, AND injects an anti-fingerprinting '
                      'shim that randomizes Canvas, WebGL, audio, font metrics, '
                      'screen dimensions, hardware concurrency, plugins, battery, '
                      'speech voices, high-resolution timers, and bounding-box '
                      'measurements. The fingerprint stays stable per site across '
                      'launches but differs between sites and between users. '
                      'When Incognito is also enabled for this site, the '
                      'fingerprint is rerolled on every app launch so the '
                      'site cannot re-identify you across cold restarts.',
                ),
              ],
            ),
            subtitle: const Text(
              'Anti-fingerprinting + force tracker blocking',
            ),
            value: _trackingProtectionEnabled,
            onChanged: (bool value) {
              setState(() {
                _trackingProtectionEnabled = value;
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
            subtitle: Text(
              _trackingProtectionEnabled
                  ? 'Forced on by Tracking Protection'
                  : 'Strip tracking parameters from URLs',
            ),
            value: _clearUrlEnabled || _trackingProtectionEnabled,
            onChanged: _trackingProtectionEnabled
                ? null
                : (bool value) {
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
              _trackingProtectionEnabled
                  ? 'Forced on by Tracking Protection'
                  : (DnsBlockService.instance.hasBlocklist
                      ? dnsBlockLevelNames[DnsBlockService.instance.level]
                      : 'Not configured'),
            ),
            value: _dnsBlockEnabled || _trackingProtectionEnabled,
            onChanged: _trackingProtectionEnabled
                ? null
                : (DnsBlockService.instance.hasBlocklist
                    ? (bool value) {
                        setState(() {
                          _dnsBlockEnabled = value;
                        });
                      }
                    : null),
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
              _trackingProtectionEnabled
                  ? 'Forced on by Tracking Protection'
                  : (ContentBlockerService.instance.hasRules
                      ? '${ContentBlockerService.instance.totalRuleCount} rules'
                      : 'Not configured'),
            ),
            value: _contentBlockEnabled || _trackingProtectionEnabled,
            onChanged: _trackingProtectionEnabled
                ? null
                : (ContentBlockerService.instance.hasRules
                    ? (bool value) {
                        setState(() {
                          _contentBlockEnabled = value;
                        });
                      }
                    : null),
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
                _trackingProtectionEnabled
                    ? 'Forced on by Tracking Protection'
                    : (LocalCdnService.instance.hasCache
                        ? '${LocalCdnService.instance.resourceCount} cached resources'
                        : 'Download the cache in app settings first'),
              ),
              value: (_localCdnEnabled || _trackingProtectionEnabled) &&
                  LocalCdnService.instance.hasCache,
              onChanged: _trackingProtectionEnabled
                  ? null
                  : (LocalCdnService.instance.hasCache
                      ? (bool value) {
                          setState(() {
                            _localCdnEnabled = value;
                          });
                        }
                      : null),
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
          SwitchListTile(
            title: Row(
              children: const [
                Flexible(child: Text('HTML caching')),
                HintButton(
                  title: 'HTML Caching',
                  description:
                      'Render this site from a cached HTML snapshot for '
                      'instant first paint on cold start, then swap to the '
                      'live page once the cached parse settles.\n\n'
                      'Off (default): the cache is only consulted when the '
                      'device is offline, so an online cold start always '
                      'goes straight to live and never shows stale content. '
                      'Snapshots are still saved in the background so the '
                      'offline fallback works on the next launch.\n\n'
                      'On: trades a momentary glimpse of stale content for '
                      'a faster first paint on every cold start.',
                ),
              ],
            ),
            subtitle: const Text(
              'Show cached page on cold start (offline fallback always on)',
            ),
            value: _htmlCachingEnabled,
            onChanged: (bool value) {
              setState(() {
                _htmlCachingEnabled = value;
              });
            },
          ),
          if (widget.useContainers)
            Builder(builder: (context) {
              final blockedBy = widget.notificationsBlockedBySite;
              // The conflict gate only forbids ENABLING. If the toggle
              // is already on (state predates a proxy edit on another
              // site), the user can still turn it off — we just don't
              // let them flip it back on while the conflict stands.
              final blocked = blockedBy != null && !_notificationsEnabled;
              final permissionDenied = _notificationsEnabled &&
                  NotificationService.instance.permissionGranted == false;
              final Widget? subtitle;
              if (blocked) {
                subtitle = Text(
                  'Cannot enable: "$blockedBy" is already polling in '
                  'background with a different proxy. Android allows only '
                  'one proxy at a time.',
                );
              } else if (permissionDenied) {
                subtitle = Text(
                  'Notifications denied. Enable in Settings → '
                  '${Platform.isIOS ? "Notifications → WebSpace" : "WebSpace → Notifications"}.',
                );
              } else {
                subtitle = null;
              }
              return SwitchListTile(
                title: Row(
                  children: const [
                    Flexible(child: Text('Notifications')),
                    HintButton(
                      title: 'Notifications',
                      description:
                          'Allow this site to show system notifications. '
                          'Keeps the site polling in the background so '
                          'notifications fire even when you are on a '
                          'different tab.',
                    ),
                  ],
                ),
                subtitle: subtitle,
                value: _notificationsEnabled,
                onChanged: blocked
                    ? null
                    : (bool value) async {
                        setState(() {
                          _notificationsEnabled = value;
                        });
                        if (!value) return;
                        // First-time background-limits info dialog
                        // (NOTIF-005-{I,A}); idempotent via a SharedPreferences
                        // flag. Show before requesting OS permission so the
                        // user understands what to expect before tapping Allow.
                        await maybeShowBackgroundNotificationLimitsDialog(context);
                        // NOTIF-007 / 16.1: request OS permission proactively
                        // at toggle time, not lazily on first notification.
                        // Repeat calls after a denial are harmless (the OS
                        // returns the cached decision).
                        await NotificationService.instance.requestPermission();
                      },
              );
            }),
          if (Platform.isAndroid)
            ListTile(
              title: Row(
                children: const [
                  Flexible(child: Text('Protected content (DRM)')),
                  HintButton(
                    title: 'Protected content (DRM)',
                    description:
                        'Controls whether this site may play DRM-protected '
                        'media (Widevine/EME), e.g. the Spotify web player.\n\n'
                        'Ask (default): a popup asks the first time the site '
                        'requests it, then remembers your choice.\n'
                        'Always allow / Always block: skip the popup.\n\n'
                        'Allowing lets the site provision a device identifier '
                        'to decrypt media. Android only — other platforms '
                        'cannot play Widevine content.',
                  ),
                ],
              ),
              trailing: DropdownButton<bool?>(
                value: _protectedContentAllowed,
                onChanged: (v) =>
                    setState(() => _protectedContentAllowed = v),
                items: const <DropdownMenuItem<bool?>>[
                  DropdownMenuItem<bool?>(value: null, child: Text('Ask')),
                  DropdownMenuItem<bool?>(
                      value: true, child: Text('Always allow')),
                  DropdownMenuItem<bool?>(
                      value: false, child: Text('Always block')),
                ],
              ),
            ),
          ..._buildLocationSection(),
          DomainClaimsEditor(
            model: widget.webViewModel,
            otherSites: widget.otherSites,
            onChanged: (next) {
              widget.webViewModel.domainClaims = next;
            },
          ),
          const SizedBox(height: 8),
          if (widget.onClearCookies != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Builder(builder: (context) {
                final label = widget.useContainers ? 'Clear Site Data' : 'Clear Cookies';
                final dialogBody = widget.useContainers
                    ? 'This wipes cookies, localStorage, IndexedDB, '
                        'ServiceWorkers, and the HTTP cache for this site. '
                        'The site will reload with a fresh empty container.'
                    : 'Are you sure you want to clear all cookies for this site?';
                final snack = widget.useContainers ? 'Site data cleared' : 'Cookies cleared';
                return OutlinedButton.icon(
                  icon: Icon(Icons.cookie, color: Colors.red),
                  label: Text(label, style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.red)),
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: Text(label),
                        content: Text(dialogBody),
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
                          SnackBar(content: Text(snack)),
                        );
                      }
                    }
                  },
                );
              }),
            ),
          // Imported file:// sites have no fetchable URL; sharing the
          // QR would only ship a synthetic file:///<name> handle that the
          // receiving device can't load, so the action is hidden.
          if (!widget.webViewModel.initUrl.startsWith('file://'))
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: OutlinedButton.icon(
                icon: const Icon(Icons.qr_code),
                label: const Text('Share QR'),
                onPressed: () => showSiteSettingsQrShareDialog(
                  context,
                  widget.webViewModel,
                ),
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
      ),
    );
  }
}

const _kBgNotifInfoShownPrefKey = 'bgNotificationLimitsInfoShown';

/// Per NOTIF-005-{I,A}: surface OS background-execution limits the first
/// time the user enables Notifications on any site. iOS and Android share
/// the same shape — a brief grace window plus opportunistic ~15-30-min
/// reloads — so one platform-aware dialog covers both. Shown once per
/// install; the "shown" flag is stored in SharedPreferences so a
/// subsequent re-toggle (or a different site's toggle) doesn't repeat it.
Future<void> maybeShowBackgroundNotificationLimitsDialog(
  BuildContext context,
) async {
  if (!Platform.isIOS && !Platform.isAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kBgNotifInfoShownPrefKey) == true) return;
  if (!context.mounted) return;
  final isIOS = Platform.isIOS;
  final title = isIOS
      ? 'Background notifications on iOS'
      : 'Background notifications on Android';
  final body = isIOS
      ? 'iOS limits background execution. Notifications arrive while '
          'WebSpace is open or in the recent-tasks list. After WebSpace is '
          'fully suspended, iOS schedules background refreshes opportunistically '
          '— typically every 15-30 minutes — at which point your sites are '
          'reloaded and any pending notifications fire.'
      : 'Android limits background execution. Notifications arrive while '
          'WebSpace is open or in recent tasks. While backgrounded, the app '
          'reloads notification sites every ~15 minutes when the system '
          'permits. If Android kills WebSpace under memory pressure, '
          'notifications stop until the next launch.';
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  await prefs.setBool(_kBgNotifInfoShownPrefKey, true);
}

/// Three-way segmented control state for the per-site geolocation row.
/// Maps to LocationMode at save time:
///   off    -> LocationMode.off     (no shim)
///   custom -> LocationMode.spoof   (static user-supplied coords)
///   live   -> LocationMode.live    (real device GPS via the shim's
///                                   getRealLocation handler)
enum _LocationSegment { off, staticCoords, live }

/// Provider tier shown by the live-mode segment picker. GPS and GSM are
/// the two OS-level provider strategies; the "Approximate" switch
/// rendered under GPS modulates whether the JS shim snaps the result,
/// so it is not a separate provider — see [LocationGranularity].
enum _LiveProvider { gps, gsm }

