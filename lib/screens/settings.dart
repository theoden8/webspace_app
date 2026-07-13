import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
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

/// Render a Firefox UA for a randomly chosen platform at the current Firefox
/// version. The version is scraped from Firefox source at runtime by
/// [FirefoxUserAgentService] (falling back to the bundled default offline),
/// so the randomize button stays current without an app release.
String generateRandomUserAgent() =>
    FirefoxUserAgentService.instance.randomUserAgent();

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
  late bool _kioskMode;
  late bool _clearUrlEnabled;
  late bool _dnsBlockEnabled;
  late bool _contentBlockEnabled;
  late bool _trackingProtectionEnabled;
  late bool _letterboxEnabled;
  late bool _localCdnEnabled;
  late bool _blockAutoRedirects;
  late bool _externalLinksInBrowser;
  late bool _fullscreenMode;
  late bool _htmlCachingEnabled;
  late bool _notificationsEnabled;
  bool? _protectedContentAllowed;
  String? _selectedLanguage;
  late int _zoomPercent;
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
    // effectiveUserAgent so a preset site's field shows the string the
    // webview actually sends (current version), not the stored snapshot.
    final ua = widget.webViewModel.effectiveUserAgent;
    return ua == '' ? (widget.webViewModel.defaultUserAgent ?? '') : ua;
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
    // Load the timezone polygon dataset on demand here (it is no longer loaded
    // at app startup) so the "From picked location" preview/resolution works.
    if (!TimezoneLocationService.instance.isReady) {
      TimezoneLocationService.instance.loadFromCacheIfPresent().then((_) {
        if (mounted) setState(() {});
      });
    }
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
        'letterboxEnabled': _letterboxEnabled,
        'localCdnEnabled': _localCdnEnabled,
        'blockAutoRedirects': _blockAutoRedirects,
        'externalLinksInBrowser': _externalLinksInBrowser,
        'fullscreenMode': _fullscreenMode,
        'htmlCachingEnabled': _htmlCachingEnabled,
        'notificationsEnabled': _notificationsEnabled,
        'protectedContentAllowed': _protectedContentAllowed,
        'selectedLanguage': _selectedLanguage,
        'zoomPercent': _zoomPercent,
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
    final loc = AppLocalizations.of(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc.siteSettingsDiscardDialogTitle),
        content: Text(loc.siteSettingsDiscardDialogBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(loc.siteSettingsDiscardKeepEditing),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              loc.siteSettingsDiscardConfirm,
              style: const TextStyle(color: Colors.red),
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
    _kioskMode = m.kioskMode;
    _clearUrlEnabled = m.clearUrlEnabled;
    _dnsBlockEnabled = m.dnsBlockEnabled;
    _contentBlockEnabled = m.contentBlockEnabled;
    _trackingProtectionEnabled = m.trackingProtectionEnabled;
    _letterboxEnabled = m.letterboxEnabled;
    _localCdnEnabled = m.localCdnEnabled;
    _blockAutoRedirects = m.blockAutoRedirects;
    _externalLinksInBrowser = m.externalLinksInBrowser;
    _fullscreenMode = m.fullscreenMode;
    _htmlCachingEnabled = m.htmlCachingEnabled;
    _notificationsEnabled = m.notificationsEnabled;
    _protectedContentAllowed = m.protectedContentAllowed;
    _selectedLanguage = m.language;
    _zoomPercent = m.zoomPercent;
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
    final loc = AppLocalizations.of(context);
    if (_proxySettings.type == ProxyType.DEFAULT) {
      return null;
    }

    if (value == null || value.isEmpty) {
      return loc.siteSettingsProxyAddressRequired;
    }

    final parts = value.split(':');
    if (parts.length != 2) {
      return loc.siteSettingsProxyAddressFormatError;
    }

    final port = int.tryParse(parts[1]);
    if (port == null || port < 1 || port > 65535) {
      return loc.siteSettingsProxyInvalidPort;
    }

    return null;
  }

  String _userScriptsSubtitle() {
    final loc = AppLocalizations.of(context);
    final siteCount = widget.webViewModel.userScripts.where((s) => s.enabled).length;
    final enabledIds = widget.webViewModel.enabledGlobalScriptIds;
    final globalCount = widget.globalUserScripts
        .where((s) => enabledIds.contains(s.id))
        .length;
    final parts = <String>[];
    if (siteCount > 0) parts.add(loc.siteSettingsUserScriptsSiteCount(siteCount));
    if (globalCount > 0) parts.add(loc.siteSettingsUserScriptsGlobalCount(globalCount));
    return parts.isEmpty
        ? loc.siteSettingsUserScriptsNone
        : loc.siteSettingsUserScriptsActive(parts.join(', '));
  }

  Widget _buildDnsStatsCard() {
    final loc = AppLocalizations.of(context);
    final stats = DnsBlockService.instance.statsForSite(widget.webViewModel.siteId);
    if (stats.total == 0) {
      return const SizedBox.shrink();
    }
    final totalValue = '${stats.total}';
    final allowedValue = '${stats.allowed}';
    final blockedValue = '${stats.blocked}';
    final blockRateValue = '${stats.blockRate.toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _buildDnsStatChip(totalValue, loc.siteSettingsDnsStatTotal, Colors.blue),
          const SizedBox(width: 6),
          _buildDnsStatChip(allowedValue, loc.siteSettingsDnsStatAllowed, Colors.green),
          const SizedBox(width: 6),
          _buildDnsStatChip(blockedValue, loc.siteSettingsDnsStatBlocked, Colors.red),
          const SizedBox(width: 6),
          _buildDnsStatChip(blockRateValue, loc.siteSettingsDnsStatBlocked, Colors.orange),
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
    final loc = AppLocalizations.of(context);
    // Only validate and update proxy settings on supported platforms
    if (PlatformInfo.isProxySupported) {
      // Validate proxy address if needed
      final proxyError = _validateProxyAddress(_proxyAddressController.text);
      if (proxyError != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(loc.siteSettingsProxyError(proxyError))),
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
        // setUserAgent re-attaches a preset when the text matches a
        // generated shape, so randomized UAs keep re-rendering at the
        // current Firefox version instead of freezing as strings.
        widget.webViewModel.setUserAgent(_userAgentController.text);
      }
      widget.webViewModel.javascriptEnabled = _javascriptEnabled;
      widget.webViewModel.thirdPartyCookiesEnabled = _thirdPartyCookiesEnabled;
      widget.webViewModel.incognito = _incognito;
      widget.webViewModel.alwaysOpenHome = _alwaysOpenHome;
      widget.webViewModel.kioskMode = _kioskMode;
      widget.webViewModel.clearUrlEnabled = _clearUrlEnabled;
      widget.webViewModel.dnsBlockEnabled = _dnsBlockEnabled;
      widget.webViewModel.contentBlockEnabled = _contentBlockEnabled;
      widget.webViewModel.trackingProtectionEnabled = _trackingProtectionEnabled;
      widget.webViewModel.letterboxEnabled = _letterboxEnabled;
      widget.webViewModel.localCdnEnabled = _localCdnEnabled;
      widget.webViewModel.blockAutoRedirects = _blockAutoRedirects;
      widget.webViewModel.externalLinksInBrowser = _externalLinksInBrowser;
      widget.webViewModel.fullscreenMode = _fullscreenMode;
      widget.webViewModel.htmlCachingEnabled = _htmlCachingEnabled;
      widget.webViewModel.notificationsEnabled = _notificationsEnabled;
      widget.webViewModel.protectedContentAllowed = _protectedContentAllowed;
      widget.webViewModel.language = _selectedLanguage;
      widget.webViewModel.zoomPercent = _zoomPercent;
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
      // Persist the EFFECTIVE timezone string. The polygon dataset is loaded
      // only here (settings), so resolving coords -> IANA zone at save time
      // lets the runtime read a stored value and keeps the multi-MB dataset
      // off the cold-start path. Tracking Protection forces from-location when
      // coords are set, mirroring _buildTimezoneDropdown's forceFromLocation.
      final bool effFromLocation = derivesTimezoneFromLocation(
        spoofTimezoneFromLocation: _spoofTimezoneFromLocation,
        trackingProtectionEnabled: _trackingProtectionEnabled,
        spoofLatitude: lat,
        spoofLongitude: lng,
      );
      if (effFromLocation && lat != null && lng != null) {
        final resolved = TimezoneLocationService.instance.lookup(lat, lng);
        // Don't clobber a previously-resolved zone with null if the dataset
        // isn't loaded right now.
        widget.webViewModel.spoofTimezone =
            resolved ?? widget.webViewModel.spoofTimezone;
      } else {
        widget.webViewModel.spoofTimezone = _spoofTimezone;
      }
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
        SnackBar(content: Text(loc.siteSettingsSavedSnack)),
      );

      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSettingsSaved?.call();
      });
    } catch (e) {
      final errorText = '$e';
      rootScaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(loc.siteSettingsSaveError(errorText))),
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
    final loc = AppLocalizations.of(context);
    final lat = double.tryParse(_latitudeController.text.trim());
    final lng = double.tryParse(_longitudeController.text.trim());
    final hasCoords = lat != null && lng != null;
    final acc = double.tryParse(_accuracyController.text.trim()) ?? 50.0;

    final hint = HintButton(
      title: loc.siteSettingsGeolocation,
      description: loc.siteSettingsGeolocationHint,
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
        ButtonSegment(
            value: _LocationSegment.off,
            icon: const Icon(Icons.location_disabled),
            label: Text(loc.siteSettingsLocationOff)),
        ButtonSegment(
            value: _LocationSegment.staticCoords,
            icon: const Icon(Icons.map_outlined),
            label: Text(loc.siteSettingsLocationStatic)),
        ButtonSegment(
            value: _LocationSegment.live,
            icon: const Icon(Icons.my_location),
            label: Text(loc.siteSettingsLocationLive)),
      ],
      selected: {selected},
      onSelectionChanged: onSegmentChanged,
      showSelectedIcon: false,
    );

    Widget detail;
    switch (selected) {
      case _LocationSegment.off:
        detail = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            loc.siteSettingsLocationOffDetail,
            style: const TextStyle(fontSize: 12),
          ),
        );
        break;
      case _LocationSegment.live:
        detail = Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                loc.siteSettingsLocationLiveDetail,
                style: const TextStyle(fontSize: 12),
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
                  segments: [
                    ButtonSegment(
                      value: _LiveProvider.gps,
                      icon: const Icon(Icons.gps_fixed),
                      label: Text(loc.siteSettingsLocationProviderGps),
                    ),
                    ButtonSegment(
                      value: _LiveProvider.gsm,
                      icon: const Icon(Icons.cell_tower),
                      label: Text(loc.siteSettingsLocationProviderGsm),
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
                  title: Text(loc.siteSettingsLocationApproximate),
                  subtitle: Text(
                    loc.siteSettingsLocationApproximateSubtitle,
                    style: const TextStyle(fontSize: 11),
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
                    loc.siteSettingsLocationGranularityGps,
                  LocationGranularity.approximate =>
                    loc.siteSettingsLocationGranularityApproximate,
                  LocationGranularity.gsm =>
                    loc.siteSettingsLocationGranularityGsm,
                },
                style: const TextStyle(fontSize: 11),
              ),
            ],
          ),
        );
        break;
      case _LocationSegment.staticCoords:
        if (hasCoords) {
          final coordsText =
              '${lat.toStringAsFixed(6)}, ${lng.toStringAsFixed(6)}  '
              '±${acc.toStringAsFixed(0)}m';
          detail = ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Text(coordsText),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: loc.siteSettingsLocationEditTooltip,
                  icon: const Icon(Icons.edit_location_alt_outlined),
                  onPressed: _openLocationPicker,
                ),
                IconButton(
                  tooltip: loc.siteSettingsLocationClearTooltip,
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
                Expanded(child: Text(
                  loc.siteSettingsLocationNoneSet,
                  style: const TextStyle(fontSize: 12),
                )),
                OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: Text(loc.siteSettingsLocationPick),
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
            children: [
              Text(loc.siteSettingsGeolocation,
                  style: const TextStyle(fontWeight: FontWeight.w500)),
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
    final loc = AppLocalizations.of(context);
    final tzReady = TimezoneLocationService.instance.isReady;
    final lat = double.tryParse(_latitudeController.text.trim());
    final lng = double.tryParse(_longitudeController.text.trim());
    final hasCoords = lat != null && lng != null;
    // Preview what the dataset would resolve to right now, so the user can
    // see whether the lookup will succeed for their picked coords. Falls
    // back to a hint if either prerequisite is missing.
    final preview = (tzReady && hasCoords)
        ? (TimezoneLocationService.instance.lookup(lat, lng) ??
            loc.siteSettingsTimezonePreviewNoMatch)
        : (!tzReady
            ? loc.siteSettingsTimezonePreviewNeedsDataset
            : loc.siteSettingsTimezonePreviewNeedsLocation);

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
          child: Text(loc.siteSettingsTimezoneFromLocation(preview)),
        ));
        insertedFromLocation = true;
      }
    }
    // Defensive fallback: if commonTimezones ever loses the System
    // default entry, still expose the option somewhere.
    if (!insertedFromLocation) {
      items.insert(0, DropdownMenuItem<String?>(
        value: _kFromLocationSentinel,
        child: Text(loc.siteSettingsTimezoneFromLocation(preview)),
      ));
    }

    return DropdownButtonFormField<String?>(
      value: value,
      decoration: InputDecoration(
        labelText: loc.siteSettingsTimezoneLabel,
        helperText: forceFromLocation
            ? loc.siteSettingsTimezoneForcedHelper
            : loc.siteSettingsTimezoneHelper,
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
    final loc = AppLocalizations.of(context);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Text(loc.siteSettingsLocationSectionTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      ),
      _buildLocationTile(),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: _buildTimezoneDropdown(),
      ),
    ];
  }

  Widget _buildWebRtcTile() {
    final loc = AppLocalizations.of(context);
    return ListTile(
      title: Row(
        children: [
          Flexible(child: Text(loc.siteSettingsWebRtcPolicy)),
          HintButton(
            title: loc.siteSettingsWebRtcHintTitle,
            description: loc.siteSettingsWebRtcHintBody,
          ),
        ],
      ),
      trailing: DropdownButton<WebRtcPolicy>(
        value: _webRtcPolicy,
        onChanged: (v) {
          if (v != null) setState(() => _webRtcPolicy = v);
        },
        items: [
          DropdownMenuItem(
              value: WebRtcPolicy.defaultPolicy,
              child: Text(loc.siteSettingsWebRtcDefault)),
          DropdownMenuItem(
              value: WebRtcPolicy.relayOnly,
              child: Text(loc.siteSettingsWebRtcRelayOnly)),
          DropdownMenuItem(
              value: WebRtcPolicy.disabled,
              child: Text(loc.siteSettingsWebRtcDisabled)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
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
      appBar: AppBar(title: Text(loc.siteSettingsTitle)),
      body: ListView(
        children: [
          // Only show proxy settings on supported platforms
          if (PlatformInfo.isProxySupported) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                loc.siteSettingsProxyShared,
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
            ListTile(
              title: Text(loc.siteSettingsProxyType),
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
                    labelText: loc.siteSettingsProxyAddress,
                    hintText: loc.siteSettingsProxyAddressHint,
                    helperText: loc.siteSettingsProxyAddressHelper,
                    border: const OutlineInputBorder(),
                  ),
                  validator: _validateProxyAddress,
                ),
              ),
              CheckboxListTile(
                title: Text(loc.siteSettingsProxyRequiresAuth),
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
                      labelText: loc.siteSettingsProxyUsername,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  child: TextFormField(
                    controller: _proxyPasswordController,
                    obscureText: _obscureProxyPassword,
                    decoration: InputDecoration(
                      labelText: loc.siteSettingsProxyPassword,
                      border: const OutlineInputBorder(),
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
          _buildWebRtcTile(),
          SwitchListTile(
            title: Text(loc.siteSettingsJavascriptEnabled),
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
                  decoration: InputDecoration(labelText: loc.siteSettingsUserAgent),
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
                labelText: loc.siteSettingsLanguage,
                helperText: loc.siteSettingsLanguageHelper,
                border: const OutlineInputBorder(),
              ),
              items: _languages.map((entry) {
                final label = entry.key == null
                    ? loc.siteSettingsLanguageSystemDefault
                    : entry.value;
                return DropdownMenuItem<String?>(
                  value: entry.key,
                  child: Text(label),
                );
              }).toList(),
              onChanged: (String? value) {
                setState(() {
                  _selectedLanguage = value;
                });
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 0.0),
            child: Row(
              children: [
                Expanded(child: Text(loc.siteSettingsPageZoom)),
                IconButton(
                  icon: const Icon(Icons.remove),
                  tooltip: loc.siteSettingsZoomOut,
                  onPressed: _zoomPercent > kMinZoomPercent
                      ? () => setState(() {
                            _zoomPercent =
                                clampZoomPercent(_zoomPercent - 10);
                          })
                      : null,
                ),
                GestureDetector(
                  onTap: () => setState(() {
                    _zoomPercent = kDefaultZoomPercent;
                  }),
                  child: SizedBox(
                    width: 56,
                    child: Builder(builder: (context) {
                      final zoomLabel = '$_zoomPercent%';
                      return Text(
                        zoomLabel,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      );
                    }),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: loc.siteSettingsZoomIn,
                  onPressed: _zoomPercent < kMaxZoomPercent
                      ? () => setState(() {
                            _zoomPercent =
                                clampZoomPercent(_zoomPercent + 10);
                          })
                      : null,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 0.0, 16.0, 8.0),
            child: Slider(
              value: _zoomPercent.toDouble(),
              min: kMinZoomPercent.toDouble(),
              max: kMaxZoomPercent.toDouble(),
              divisions: (kMaxZoomPercent - kMinZoomPercent) ~/ 10,
              label: '$_zoomPercent%',
              onChanged: (double value) {
                setState(() {
                  _zoomPercent = clampZoomPercent((value / 10).round() * 10);
                });
              },
            ),
          ),
          SwitchListTile(
            title: Text(loc.siteSettingsThirdPartyCookies),
            value: _thirdPartyCookiesEnabled,
            onChanged: (bool value) {
              setState(() {
                _thirdPartyCookiesEnabled = value;
              });
            },
          ),
          SwitchListTile(
            title: Text(loc.siteSettingsIncognito),
            subtitle: Text(loc.siteSettingsIncognitoSubtitle),
            value: _incognito,
            onChanged: (bool value) {
              setState(() {
                _incognito = value;
              });
            },
          ),
          SwitchListTile(
            title: Text(loc.siteSettingsAlwaysOpenHome),
            subtitle: Text(
              _incognito
                  ? loc.siteSettingsAlwaysOpenHomeForced
                  : loc.siteSettingsAlwaysOpenHomeSubtitle,
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
                Flexible(child: Text(loc.siteSettingsKioskMode)),
                HintButton(
                  title: loc.siteSettingsKioskMode,
                  description: loc.siteSettingsKioskModeHint,
                ),
              ],
            ),
            value: _kioskMode,
            onChanged: (bool value) {
              setState(() {
                _kioskMode = value;
              });
            },
          ),
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.siteSettingsTrackingProtection)),
                HintButton(
                  title: loc.siteSettingsTrackingProtection,
                  description: loc.siteSettingsTrackingProtectionHint,
                ),
              ],
            ),
            subtitle: Text(loc.siteSettingsTrackingProtectionSubtitle),
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
                Flexible(child: Text(loc.siteSettingsLetterboxTitle)),
                HintButton(
                  title: loc.siteSettingsLetterboxTitle,
                  description: loc.siteSettingsWindowSizeHelper,
                ),
              ],
            ),
            value: _letterboxEnabled && _trackingProtectionEnabled,
            onChanged: _trackingProtectionEnabled
                ? (bool value) {
                    setState(() {
                      _letterboxEnabled = value;
                    });
                  }
                : null,
          ),
          SwitchListTile(
            title: Row(
              children: [
                Text(loc.siteSettingsClearUrls),
                HintButton(
                  title: loc.siteSettingsClearUrls,
                  description: loc.siteSettingsClearUrlsHint,
                ),
              ],
            ),
            subtitle: Text(
              _trackingProtectionEnabled
                  ? loc.siteSettingsForcedByTrackingProtection
                  : loc.siteSettingsClearUrlsSubtitle,
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
                Text(loc.siteSettingsDnsBlocklist),
                HintButton(
                  title: loc.siteSettingsDnsBlocklist,
                  description: loc.siteSettingsDnsBlocklistHint,
                ),
              ],
            ),
            subtitle: Text(
              _trackingProtectionEnabled
                  ? loc.siteSettingsForcedByTrackingProtection
                  : (DnsBlockService.instance.hasBlocklist
                      ? dnsBlockLevelNames[DnsBlockService.instance.level]
                      : loc.siteSettingsNotConfigured),
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
                Flexible(child: Text(loc.siteSettingsContentBlocker)),
                HintButton(
                  title: loc.siteSettingsContentBlocker,
                  description: loc.siteSettingsContentBlockerHint,
                ),
              ],
            ),
            subtitle: Text(
              _trackingProtectionEnabled
                  ? loc.siteSettingsForcedByTrackingProtection
                  : (ContentBlockerService.instance.hasRules
                      ? loc.siteSettingsContentBlockerRuleCount(
                          ContentBlockerService.instance.totalRuleCount)
                      : loc.siteSettingsNotConfigured),
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
                  Text(loc.siteSettingsLocalCdn),
                  HintButton(
                    title: loc.siteSettingsLocalCdn,
                    description: loc.siteSettingsLocalCdnHint,
                  ),
                ],
              ),
              subtitle: Text(
                _trackingProtectionEnabled
                    ? loc.siteSettingsForcedByTrackingProtection
                    : (LocalCdnService.instance.hasCache
                        ? loc.siteSettingsLocalCdnResourceCount(
                            LocalCdnService.instance.resourceCount)
                        : loc.siteSettingsLocalCdnNeedsCache),
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
            title: Text(loc.siteSettingsUserScripts),
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
                Flexible(child: Text(loc.siteSettingsBlockAutoRedirects)),
                HintButton(
                  title: loc.siteSettingsBlockAutoRedirectsHintTitle,
                  description: loc.siteSettingsBlockAutoRedirectsHint,
                ),
              ],
            ),
            subtitle: Text(loc.siteSettingsBlockAutoRedirectsSubtitle),
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
                Flexible(child: Text(loc.siteSettingsExternalLinksInBrowser)),
                HintButton(
                  title: loc.siteSettingsExternalLinksInBrowserHintTitle,
                  description: loc.siteSettingsExternalLinksInBrowserHint,
                ),
              ],
            ),
            subtitle: Text(loc.siteSettingsExternalLinksInBrowserSubtitle),
            value: _externalLinksInBrowser,
            onChanged: (bool value) {
              setState(() {
                _externalLinksInBrowser = value;
              });
            },
          ),
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.siteSettingsFullscreen)),
                HintButton(
                  title: loc.siteSettingsFullscreenHintTitle,
                  description: loc.siteSettingsFullscreenHint,
                ),
              ],
            ),
            subtitle: Text(loc.siteSettingsFullscreenSubtitle),
            value: _fullscreenMode,
            onChanged: (bool value) {
              setState(() {
                _fullscreenMode = value;
              });
            },
          ),
          SwitchListTile(
            title: Row(
              children: [
                Flexible(child: Text(loc.siteSettingsHtmlCaching)),
                HintButton(
                  title: loc.siteSettingsHtmlCachingHintTitle,
                  description: loc.siteSettingsHtmlCachingHint,
                ),
              ],
            ),
            subtitle: Text(loc.siteSettingsHtmlCachingSubtitle),
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
                  loc.siteSettingsNotificationsBlockedByProxy(blockedBy),
                );
              } else if (permissionDenied) {
                final settingsPath = Platform.isIOS
                    ? 'Notifications → WebSpace'
                    : 'WebSpace → Notifications';
                subtitle = Text(
                  loc.siteSettingsNotificationsDenied(settingsPath),
                );
              } else {
                subtitle = null;
              }
              return SwitchListTile(
                title: Row(
                  children: [
                    Flexible(child: Text(loc.siteSettingsNotifications)),
                    HintButton(
                      title: loc.siteSettingsNotifications,
                      description: loc.siteSettingsNotificationsHint,
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
                children: [
                  Flexible(child: Text(loc.siteSettingsProtectedContent)),
                  HintButton(
                    title: loc.siteSettingsProtectedContent,
                    description: loc.siteSettingsProtectedContentHint,
                  ),
                ],
              ),
              subtitle: _trackingProtectionEnabled
                  ? Text(loc.siteSettingsProtectedContentBlockedByEtp)
                  : null,
              trailing: DropdownButton<bool?>(
                value: _trackingProtectionEnabled
                    ? false
                    : _protectedContentAllowed,
                onChanged: _trackingProtectionEnabled
                    ? null
                    : (v) => setState(() => _protectedContentAllowed = v),
                items: <DropdownMenuItem<bool?>>[
                  DropdownMenuItem<bool?>(
                      value: null, child: Text(loc.siteSettingsProtectedContentAsk)),
                  DropdownMenuItem<bool?>(
                      value: true, child: Text(loc.siteSettingsProtectedContentAllow)),
                  DropdownMenuItem<bool?>(
                      value: false, child: Text(loc.siteSettingsProtectedContentBlock)),
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
                final label = widget.useContainers
                    ? loc.siteSettingsClearSiteData
                    : loc.siteSettingsClearCookies;
                final dialogBody = widget.useContainers
                    ? loc.siteSettingsClearSiteDataBody
                    : loc.siteSettingsClearCookiesBody;
                final snack = widget.useContainers
                    ? loc.siteSettingsClearSiteDataDone
                    : loc.siteSettingsClearCookiesDone;
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
                            child: Text(loc.commonCancel),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(loc.siteSettingsClearConfirm,
                                style: const TextStyle(color: Colors.red)),
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
                label: Text(loc.siteSettingsShareQr),
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
              child: Text(loc.siteSettingsSaveButton),
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
  final loc = AppLocalizations.of(context);
  final isIOS = Platform.isIOS;
  final title = isIOS
      ? loc.siteSettingsBgNotifTitleIos
      : loc.siteSettingsBgNotifTitleAndroid;
  final body = isIOS
      ? loc.siteSettingsBgNotifBodyIos
      : loc.siteSettingsBgNotifBodyAndroid;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(loc.commonOk),
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

