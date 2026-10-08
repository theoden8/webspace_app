import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/tor_exit_countries.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/user_agent_identity.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/proxy_form_engine.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/site_search_list_service.dart';
import 'package:webspace/services/notification_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/screens/location_picker.dart';
import 'package:webspace/screens/site_behaviour.dart';
import 'package:webspace/screens/site_network.dart';
import 'package:webspace/screens/site_permissions.dart';
import 'package:webspace/screens/site_privacy.dart';
import 'package:webspace/screens/link_handling_settings.dart';
import 'package:webspace/screens/site_settings_qr.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/proxy_choice_dropdown.dart'
    show libraryRouteLabel, torRouteLabel;
import 'package:webspace/widgets/proxy_test_tile.dart';
import 'package:webspace/widgets/confirm_dialog.dart';
import 'package:webspace/widgets/dirty_guard.dart';
import 'package:webspace/widgets/root_messenger.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/toast.dart';
import 'package:webspace/widgets/site_permission_badges.dart';

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
  final VoidCallback? onClearCookies;
  final List<UserScriptConfig> globalUserScripts;
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

  /// The sites an outbound routing preference may name (LIR-014): this
  /// site's candidates on its side of the archive boundary, minus itself.
  final List<WebViewModel> routingTargets;

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
    this.routingTargets = const [],
  });

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with DirtyGuard<SettingsScreen> {
  late UserProxySettings _proxySettings;
  final _userAgentController = TextEditingController();
  final _proxyAddressController = TextEditingController();
  final _proxyUsernameController = TextEditingController();
  final _proxyPasswordController = TextEditingController();
  late bool _javascriptEnabled;
  late bool _thirdPartyCookiesEnabled;
  late bool? _httpsUpgradeEnabled;
  late bool _incognito;
  late bool _alwaysOpenHome;
  late bool _kioskMode;
  late bool _clearUrlEnabled;
  late bool _dnsBlockEnabled;
  late int? _dnsBlockLevel;
  late bool _contentBlockEnabled;
  late Set<String> _disabledFilterLists;
  late bool _trackingProtectionEnabled;
  late bool _letterboxEnabled;
  late bool _blockScreenshots;
  late bool _localCdnEnabled;
  late ExternalLinkMode _externalLinkMode;
  late bool _routeOutboundLinks;
  late List<OutboundPreference> _outboundPreferences;
  String? _searchAddress;
  late bool _searchesWeb;
  late List<String> _searchSites;
  String? _searchDefault;
  late bool _fullscreenMode;
  late bool _tabsEnabled;
  late bool _htmlCachingEnabled;
  late bool _notificationsEnabled;
  late bool _backgroundAudioEnabled;
  bool? _protectedContentAllowed;
  CaptureGrants _captures = CaptureGrants.none;
  String? _selectedLanguage;
  late int _zoomPercent;
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  final _accuracyController = TextEditingController();
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
  late WebRtcPolicy _webRtcPolicy;

  @override
  void initState() {
    super.initState();
    _loadFromModel();
    markClean();
    for (final c in _controllers) {
      c.addListener(_rebuild);
    }
    NotificationService.instance.addPermissionListener(_rebuild);
    // Load the timezone polygon dataset on demand here (it is not loaded
    // at app startup) so the "From picked location" preview/resolution works.
    if (!TimezoneLocationService.instance.isReady) {
      TimezoneLocationService.instance
          .loadFromCacheIfPresent()
          .then((_) => _rebuild());
    }
  }

  List<TextEditingController> get _controllers => [
        _userAgentController,
        _proxyAddressController,
        _proxyUsernameController,
        _proxyPasswordController,
        _latitudeController,
        _longitudeController,
        _accuracyController,
      ];

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Record snapshot() => (
        proxyType: _proxySettings.type,
        torExitCountry: _proxySettings.torExitCountry,
        savedProxyId: _proxySettings.savedProxyId,
        gatewayId: _proxySettings.gatewayId,
        credentialsId: _proxySettings.credentialsId,
        proxyAddress: _proxyAddressController.text,
        proxyUsername: _proxyUsernameController.text,
        proxyPassword: _proxyPasswordController.text,
        userAgent: _userAgentController.text,
        javascriptEnabled: _javascriptEnabled,
        thirdPartyCookiesEnabled: _thirdPartyCookiesEnabled,
        httpsUpgradeEnabled: _httpsUpgradeEnabled,
        incognito: _incognito,
        alwaysOpenHome: _alwaysOpenHome,
        kioskMode: _kioskMode,
        clearUrlEnabled: _clearUrlEnabled,
        dnsBlockEnabled: _dnsBlockEnabled,
        dnsBlockLevel: _dnsBlockLevel,
        contentBlockEnabled: _contentBlockEnabled,
        disabledFilterLists: ValueSet(_disabledFilterLists),
        trackingProtectionEnabled: _trackingProtectionEnabled,
        letterboxEnabled: _letterboxEnabled,
        blockScreenshots: _blockScreenshots,
        localCdnEnabled: _localCdnEnabled,
        externalLinkMode: _externalLinkMode,
        routeOutboundLinks: _routeOutboundLinks,
        outboundPreferences: ValueList(_outboundPreferences),
        searchAddress: _searchAddress,
        searchesWeb: _searchesWeb,
        searchSites: ValueList(_searchSites),
        searchDefault: _searchDefault,
        fullscreenMode: _fullscreenMode,
        tabsEnabled: _tabsEnabled,
        htmlCachingEnabled: _htmlCachingEnabled,
        notificationsEnabled: _notificationsEnabled,
        backgroundAudioEnabled: _backgroundAudioEnabled,
        protectedContentAllowed: _protectedContentAllowed,
        captures: _captures,
        selectedLanguage: _selectedLanguage,
        zoomPercent: _zoomPercent,
        latitude: _latitudeController.text,
        longitude: _longitudeController.text,
        accuracy: _accuracyController.text,
        spoofTimezone: _spoofTimezone,
        spoofTimezoneFromLocation: _spoofTimezoneFromLocation,
        isLiveLocation: _isLiveLocation,
        liveLocationGranularity: _liveLocationGranularity,
        webRtcPolicy: _webRtcPolicy,
      );

  /// Live browser/OS identity + validity readout for the UA field. Follows
  /// the field text as the user types (the controller listener already pokes
  /// setState); an empty field describes the platform default instead.
  /// Validity issues are only surfaced for explicit overrides — the stock
  /// default trivially carries webview tells and there is nothing the user
  /// should do about it.
  Widget _buildUserAgentIdentity(AppLocalizations loc) {
    final text = _userAgentController.text.trim();
    final isOverride = text.isNotEmpty;
    final ua =
        isOverride ? text : (widget.webViewModel.defaultUserAgent ?? '');
    if (ua.isEmpty) return const SizedBox.shrink();

    final identity = describeUserAgent(
      ua,
      currentFirefoxMajor: FirefoxUserAgentService.instance.majorVersion,
    );
    final (browserLabel, browserIcon) = switch (identity.browser) {
      UaBrowser.firefox => ('Firefox', Icons.language),
      UaBrowser.chrome => ('Chrome', Icons.language),
      UaBrowser.safari => ('Safari', Icons.language),
      UaBrowser.edge => ('Edge', Icons.language),
      UaBrowser.opera => ('Opera', Icons.language),
      UaBrowser.samsungInternet => ('Samsung Internet', Icons.language),
      UaBrowser.webview => (loc.siteSettingsUaBrowserWebView, Icons.web_asset),
      UaBrowser.unknown => (loc.siteSettingsUaBrowserUnknown, Icons.help_outline),
    };
    final (osLabel, osIcon) = switch (identity.os) {
      UaOs.windows => ('Windows', Icons.desktop_windows),
      UaOs.macos => ('macOS', Icons.laptop_mac),
      UaOs.linux => ('Linux', Icons.computer),
      UaOs.android => ('Android', Icons.android),
      UaOs.ios => ('iOS', Icons.phone_iphone),
      UaOs.unknown => (loc.siteSettingsUaOsUnknown, Icons.device_unknown),
    };
    final browserText = [browserLabel, ?identity.browserVersion].join(' ');
    final osText = [osLabel, ?identity.osVersion].join(' ');

    final issues = isOverride ? identity.issues : const <UaIssue>[];
    String issueText(UaIssue issue) => switch (issue) {
          UaIssue.malformed => loc.siteSettingsUaIssueMalformed,
          UaIssue.geckoVersionMismatch =>
            loc.siteSettingsUaIssueGeckoVersionMismatch,
          UaIssue.embeddedWebViewTell => loc.siteSettingsUaIssueWebViewTell,
          UaIssue.impossibleHybrid => loc.siteSettingsUaIssueImpossibleHybrid,
          UaIssue.staleFirefoxVersion => loc.siteSettingsUaIssueStaleFirefox(
              FirefoxUserAgentService.instance.majorVersion),
        };

    final theme = Theme.of(context);
    final subtleStyle = theme.textTheme.bodySmall;
    Widget labelled(IconData icon, {required String text,Color? color}) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: color ?? subtleStyle?.color),
            const SizedBox(width: 4),
            Text(text, style: subtleStyle),
          ],
        );
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              labelled(browserIcon, text: browserText),
              labelled(osIcon, text: osText),
              if (!isOverride)
                Text(loc.siteSettingsUserAgentSystemDefault,
                    style: subtleStyle),
              if (isOverride && issues.isEmpty)
                labelled(Icons.check_circle_outline, text: loc.siteSettingsUaLooksValid,
                    color: Colors.green),
            ],
          ),
          for (final issue in issues)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: Colors.orange),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      issueText(issue),
                      style: subtleStyle?.copyWith(color: Colors.orange),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Mirror [widget.webViewModel] into the form state.
  void _loadFromModel() {
    final m = widget.webViewModel;
    final p = PlatformInfo.isProxySupported ? m.proxySettings : null;
    _proxySettings = UserProxySettings(
      type: p?.type ?? ProxyType.DEFAULT,
      address: p?.address,
      username: p?.username,
      password: p?.password,
      torExitCountry: p?.torExitCountry,
      savedProxyId: p?.savedProxyId,
      gatewayId: p?.gatewayId,
      credentialsId: p?.credentialsId,
    );
    // effectiveUserAgent so a preset site's field shows the string the
    // webview actually sends (current version), not the stored snapshot.
    // Empty means "no override": the webview default shows as a hint, never
    // as field text — pre-filling it froze the default into storage on save.
    _userAgentController.text = m.effectiveUserAgent;
    _proxyAddressController.text = _proxySettings.address ?? '';
    _proxyUsernameController.text = _proxySettings.username ?? '';
    _proxyPasswordController.text = _proxySettings.password ?? '';
    _javascriptEnabled = m.javascriptEnabled;
    _thirdPartyCookiesEnabled = m.thirdPartyCookiesEnabled;
    _httpsUpgradeEnabled = m.httpsUpgradeEnabled;
    _incognito = m.incognito;
    _alwaysOpenHome = m.alwaysOpenHome;
    _kioskMode = m.kioskMode;
    _clearUrlEnabled = m.clearUrlEnabled;
    _dnsBlockEnabled = m.dnsBlockEnabled;
    _dnsBlockLevel = m.dnsBlockLevel;
    _contentBlockEnabled = m.contentBlockEnabled;
    _disabledFilterLists = {...m.disabledFilterLists};
    _trackingProtectionEnabled = m.trackingProtectionEnabled;
    _letterboxEnabled = m.letterboxEnabled;
    _blockScreenshots = m.blockScreenshots;
    _localCdnEnabled = m.localCdnEnabled;
    _externalLinkMode = m.externalLinkMode;
    _routeOutboundLinks = m.routeOutboundLinks;
    _outboundPreferences = [...m.outboundPreferences];
    _searchAddress = m.searchAddress;
    _searchesWeb = m.searchesWeb;
    _searchSites = [...m.searchSites];
    _searchDefault = m.searchDefault;
    _fullscreenMode = m.fullscreenMode;
    _tabsEnabled = m.tabsEnabled;
    _htmlCachingEnabled = m.htmlCachingEnabled;
    _notificationsEnabled = m.notificationsEnabled;
    _backgroundAudioEnabled = m.backgroundAudioEnabled;
    _protectedContentAllowed = m.protectedContentAllowed;
    _captures = m.captures;
    _selectedLanguage = m.language;
    _zoomPercent = m.zoomPercent;
    _latitudeController.text = m.spoofLatitude?.toString() ?? '';
    _longitudeController.text = m.spoofLongitude?.toString() ?? '';
    _accuracyController.text = m.spoofAccuracy.toString();
    _spoofTimezone = m.spoofTimezone;
    _spoofTimezoneFromLocation = m.spoofTimezoneFromLocation;
    _isLiveLocation = m.locationMode == LocationMode.live;
    _liveLocationGranularity = m.liveLocationGranularity;
    _webRtcPolicy = m.webRtcPolicy;
  }

  @override
  void dispose() {
    NotificationService.instance.removePermissionListener(_rebuild);
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  /// What a save would store, form edits included. The proxy test reads it
  /// too: the question a user asks after typing an address is whether *that*
  /// one works, and answering it about the persisted copy would be a
  /// different question.
  UserProxySettings _formProxy() => applyProxyForm(
        stored: _proxySettings,
        fields: ProxyFormFields(
          type: _proxySettings.type,
          address: _proxyAddressController.text,
          username: _proxyUsernameController.text,
          password: _proxyPasswordController.text,
          savedProxyId: _proxySettings.savedProxyId,
          gatewayId: _proxySettings.gatewayId,
          credentialsId: _proxySettings.credentialsId,
        ),
      );

  String _userScriptsSubtitle() {
    final loc = AppLocalizations.of(context);
    final siteCount = widget.webViewModel.userScripts.where((s) => s.enabled).length;
    final enabledIds = widget.webViewModel.enabledGlobalScriptIds;
    final globalCount = widget.globalUserScripts
        .where((s) => enabledIds.contains(s.id))
        .length;
    final parts = [
      if (siteCount > 0) loc.siteSettingsUserScriptsSiteCount(siteCount),
      if (globalCount > 0) loc.siteSettingsUserScriptsGlobalCount(globalCount),
    ];
    return parts.isEmpty
        ? loc.siteSettingsUserScriptsNone
        : loc.siteSettingsUserScriptsActive(parts.join(', '));
  }

  Future<void> _saveSettings() async {
    final loc = AppLocalizations.of(context);
    if (PlatformInfo.isProxySupported) {
      final proxyError = validateProxyAddress(
          loc, type: _proxySettings.type, value: _proxyAddressController.text);
      if (proxyError != null) {
        ScaffoldMessenger.of(context).toast(
          loc.siteSettingsProxyError(proxyError),
        );
        return;
      }
    }

    try {
      final m = widget.webViewModel;
      if (PlatformInfo.isProxySupported) {
        _proxySettings = _formProxy();
        m.proxySettings = _proxySettings;
        LogTag.proxy.info(
            'Saving per-site proxy for siteId=${m.siteId}: '
            '${_proxySettings.describeForLogs()}', sensitive: true);
        await m.updateProxySettings(_proxySettings);
      } else {
        final defaultProxy = UserProxySettings(type: ProxyType.DEFAULT);
        m.proxySettings = defaultProxy;
        LogTag.proxy.debug(
            'Per-site proxy unsupported on this platform; forcing DEFAULT for '
            'siteId=${m.siteId}', sensitive: true);
        await m.updateProxySettings(defaultProxy);
      }

      // Unconditional: an empty field clears the override (previously it
      // was skipped, making an override impossible to remove). setUserAgent
      // re-attaches a preset for generated shapes and drops stock
      // webview-default strings back to "no override".
      m.setUserAgent(_userAgentController.text);
      m.javascriptEnabled = _javascriptEnabled;
      m.thirdPartyCookiesEnabled = _thirdPartyCookiesEnabled;
      m.httpsUpgradeEnabled = _httpsUpgradeEnabled;
      m.incognito = _incognito;
      m.alwaysOpenHome = _alwaysOpenHome;
      m.kioskMode = _kioskMode;
      m.clearUrlEnabled = _clearUrlEnabled;
      m.dnsBlockEnabled = _dnsBlockEnabled;
      m.dnsBlockLevel = _dnsBlockLevel;
      m.contentBlockEnabled = _contentBlockEnabled;
      m.disabledFilterLists = {..._disabledFilterLists};
      m.trackingProtectionEnabled = _trackingProtectionEnabled;
      m.letterboxEnabled = _letterboxEnabled;
      m.blockScreenshots = _blockScreenshots;
      m.localCdnEnabled = _localCdnEnabled;
      m.externalLinkMode = _externalLinkMode;
      m.routeOutboundLinks = _routeOutboundLinks;
      m.outboundPreferences = [..._outboundPreferences];
      m.searchAddress = _searchAddress;
      m.searchesWeb = _searchesWeb;
      m.searchSites = [..._searchSites];
      m.searchDefault = _searchDefault;
      m.fullscreenMode = _fullscreenMode;
      m.tabsEnabled = _tabsEnabled;
      m.htmlCachingEnabled = _htmlCachingEnabled;
      m.notificationsEnabled = _notificationsEnabled;
      m.backgroundAudioEnabled = _backgroundAudioEnabled;
      m.protectedContentAllowed = _protectedContentAllowed;
      m.captures = _captures;
      m.language = _selectedLanguage;
      m.zoomPercent = _zoomPercent;
      // Live and custom coordinates are mutually exclusive in the UI; only a
      // spoofed location keeps its coordinates.
      final lat = _latitude;
      final lng = _longitude;
      final mode = _effectiveLocationMode;
      m.locationMode = mode;
      m.spoofLatitude = mode == LocationMode.spoof ? lat : null;
      m.spoofLongitude = mode == LocationMode.spoof ? lng : null;
      final accuracy = double.tryParse(_accuracyController.text.trim());
      if (accuracy != null && accuracy > 0) m.spoofAccuracy = accuracy;
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
        // Don't clobber a previously-resolved zone with null if the dataset
        // isn't loaded right now.
        m.spoofTimezone =
            TimezoneLocationService.instance.lookup(lat, longitude: lng) ??
                m.spoofTimezone;
      } else {
        m.spoofTimezone = _spoofTimezone;
      }
      m.spoofTimezoneFromLocation = _spoofTimezoneFromLocation;
      m.liveLocationGranularity = _liveLocationGranularity;
      m.webRtcPolicy = _webRtcPolicy;

      if (!mounted) return;

      // Dispose the webview so it gets recreated with the new settings, at
      // the URL it was showing.
      final currentUrl = m.currentUrl;
      m.disposeWebView();
      m.currentUrl = currentUrl;

      // Pop first so the Settings route leaves the tree before the parent
      // rebuilds. Notifying the parent inline would mark the Navigator dirty
      // while it is locked during the pop, tripping the '!_debugLocked'
      // assertion in NavigatorState.build.
      if (!await popClean()) return;

      rootScaffoldMessengerKey.currentState?.toast(loc.siteSettingsSavedSnack);

      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onSettingsSaved?.call();
      });
    } catch (e) {
      rootScaffoldMessengerKey.currentState?.toast(loc.siteSettingsSaveError('$e'));
    }
  }

  Future<bool> _openLocationPicker() async {
    final result = await Navigator.push<LocationPickerResult>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLatitude: _latitude,
          initialLongitude: _longitude,
          initialAccuracy: double.tryParse(_accuracyController.text.trim()) ?? 50.0,
        ),
      ),
    );
    if (result == null || !mounted) return false;
    setState(() {
      _latitudeController.text = result.latitude.toStringAsFixed(6);
      _longitudeController.text = result.longitude.toStringAsFixed(6);
      _accuracyController.text = result.accuracy.toString();
    });
    return true;
  }

  double? get _latitude => double.tryParse(_latitudeController.text.trim());
  double? get _longitude => double.tryParse(_longitudeController.text.trim());

  /// Location mode as the permission screen shows it and the save path
  /// stores it: the settings screen keeps the live flag and the coordinates
  /// separately.
  LocationMode get _effectiveLocationMode {
    if (_isLiveLocation) return LocationMode.live;
    return _hasStaticCoordinates ? LocationMode.spoof : LocationMode.off;
  }

  /// What the timezone dataset resolves the current coordinates to, or a hint
  /// naming the missing prerequisite. Lives here because the coordinates do.
  String _timezonePreview() {
    final loc = AppLocalizations.of(context);
    if (!TimezoneLocationService.instance.isReady) {
      return loc.siteSettingsTimezonePreviewNeedsDataset;
    }
    final (lat, lng) = (_latitude, _longitude);
    if (lat == null || lng == null) {
      return loc.siteSettingsTimezonePreviewNeedsLocation;
    }
    return TimezoneLocationService.instance.lookup(lat, longitude: lng) ??
        loc.siteSettingsTimezonePreviewNoMatch;
  }

  /// The picked coordinates as the permission row shows them, or null when
  /// none are set. Built as data before it reaches `Text(` (LOC-002): a
  /// latitude and a longitude are numbers, not translatable copy.
  String? _coordinatesPreview() {
    final (lat, lng) = (_latitude, _longitude);
    if (lat == null || lng == null) return null;
    return '${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)}';
  }

  bool get _hasStaticCoordinates => _latitude != null && _longitude != null;

  /// The subtitle names what the site actually holds, so the common question
  /// is answered without opening it.
  /// What the site runs with, not what it stores: an archived site's
  /// grants are held off underneath (ARCH-006), as the drawer badges show.
  Widget _buildPermissionsRow() {
    final loc = AppLocalizations.of(context);
    final v = _permissionValues;
    final held = heldBadges((
      location: _effectiveLocationMode,
      captures: v.effectiveCaptures,
      notifications: widget.useContainers && v.effectiveNotifications,
      protectedContent: hostIsAndroid &&
          v.effectiveProtectedContent(
                  trackingProtection: _trackingProtectionEnabled) ==
              true,
      // Not a grant (the Permissions screen says so under its switch).
      backgroundAudio: false,
    ));
    final scheme = Theme.of(context).colorScheme;
    return SummaryNavRow(
      // A key, not a shield: the Privacy row directly above leads with a
      // shield, and two shields side by side read as one thing.
      leading: const Icon(Icons.key_outlined),
      title: loc.permissionsTitle,
      summary: summariseSettings(
        loc,
        on: [
          for (final b in held)
            '${sitePermissionBadgeTitle(loc, badge: b)}: '
                '${sitePermissionBadgeState(b).label(loc)}',
        ],
        none: loc.permissionsSummaryNothingGranted,
      ),
      marks: [
        for (final b in held)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 1),
            child: Icon(sitePermissionBadgeIcon(b),
                size: 16,
                color: isRealDeviceAccess(b)
                    ? scheme.error
                    : scheme.onSurfaceVariant),
          ),
      ],
      onTap: _openPermissions,
    );
  }

  bool get _archived => widget.webViewModel.isArchiveTier;

  SitePermissionValues get _permissionValues => SitePermissionValues(
        archived: _archived,
        captures: _captures,
        notificationsEnabled: _notificationsEnabled,
        backgroundAudioEnabled: _backgroundAudioEnabled,
        protectedContentAllowed: _protectedContentAllowed,
        locationMode: _effectiveLocationMode,
        liveLocationGranularity: _liveLocationGranularity,
        hasStaticCoordinates: _hasStaticCoordinates,
        spoofTimezone: _spoofTimezone,
        spoofTimezoneFromLocation: _spoofTimezoneFromLocation,
      );

  /// Opens one of the Site screens; its row is redrawn from what it changed.
  Future<void> _push(WidgetBuilder screen) async {
    await Navigator.push<void>(context, MaterialPageRoute(builder: screen));
    _rebuild();
  }

  Future<void> _openPermissions() => _push((_) => SitePermissionsScreen(
        host: widget.webViewModel.currentUrl,
        trackingProtectionEnabled: _trackingProtectionEnabled,
        notificationsBlockedBySite: widget.notificationsBlockedBySite,
        showNotifications: widget.useContainers,
        values: _permissionValues,
        timezonePreview: _timezonePreview,
        coordinatesPreview: _coordinatesPreview,
        onOpenLocationPicker: _openLocationPicker,
        onEnableNotifications: () async {
          // First-time background-limits info dialog (NOTIF-005-{I,A});
          // idempotent via a SharedPreferences flag. Shown before the OS
          // permission request so the user knows what to expect before
          // tapping Allow.
          await maybeShowBackgroundNotificationLimitsDialog(context);
          // NOTIF-007: request the OS permission at toggle time rather than
          // lazily on the first notification. Repeat calls after a denial
          // are harmless (the OS returns the cached decision).
          await NotificationService.instance.requestPermission();
        },
        onChanged: (values) => setState(() {
          _captures = values.captures;
          _notificationsEnabled = values.notificationsEnabled;
          _backgroundAudioEnabled = values.backgroundAudioEnabled;
          _protectedContentAllowed = values.protectedContentAllowed;
          _liveLocationGranularity = values.liveLocationGranularity;
          _spoofTimezone = values.spoofTimezone;
          _spoofTimezoneFromLocation = values.spoofTimezoneFromLocation;
          _isLiveLocation = values.locationMode == LocationMode.live;
          if (values.locationMode == LocationMode.off) {
            // Off is a refusal now, so stale coordinates must not linger
            // and silently turn it back into a static grant on next open.
            _latitudeController.clear();
            _longitudeController.clear();
            _accuracyController.text = '50';
          }
        }),
      ));

  SiteBehaviourValues get _behaviourValues => SiteBehaviourValues(
        archived: _archived,
        alwaysOpenHome: _alwaysOpenHome,
        kioskMode: _kioskMode,
        fullscreenMode: _fullscreenMode,
        tabsEnabled: _tabsEnabled,
        htmlCachingEnabled: _htmlCachingEnabled,
        externalLinkMode: _externalLinkMode,
        routeOutboundLinks: _routeOutboundLinks,
        outboundPreferences: _outboundPreferences,
        searchAddress: _searchAddress,
        searchesWeb: _searchesWeb,
        searchSites: _searchSites,
        searchDefault: Scoped.fromStored(_searchDefault),
      );

  /// One of the four rows that open a screen of their own. Behaviour is what
  /// the app does with the site rather than what the site is allowed to do, so
  /// it leads the group.
  Widget _buildBehaviourRow() {
    final loc = AppLocalizations.of(context);
    final v = _behaviourValues;
    return SummaryNavRow(
      leading: const Icon(Icons.tune),
      title: loc.behaviourTitle,
      summary: summariseSettings(
        loc,
        on: [
          if (v.effectiveAlwaysOpenHome(
            incognito: _privacyValues.effectiveIncognito,
          ))
            loc.siteSettingsAlwaysOpenHome,
          if (v.kioskMode) loc.siteSettingsKioskMode,
          if (v.fullscreenMode) loc.siteSettingsFullscreen,
          if (v.effectiveHtmlCaching) loc.siteSettingsHtmlCaching,
          if (v.effectiveRouteOutboundLinks) loc.siteSettingsRouteOutboundLinks,
          ?v.effectiveExternalLinkMode.summary(loc),
        ],
        none: loc.behaviourSummaryNothingOn,
      ),
      onTap: _openBehaviour,
    );
  }

  Future<void> _openBehaviour() => _push((_) => SiteBehaviourScreen(
        host: widget.webViewModel.currentUrl,
        incognito: _privacyValues.effectiveIncognito,
        values: _behaviourValues,
        containersActive: widget.useContainers,
        routingTargets: widget.routingTargets,
        initUrl: widget.webViewModel.initUrl,
        discoveredSearchAddress: widget.webViewModel.discoveredSearchAddress,
        discoveredSearchesWeb: widget.webViewModel.discoveredSearchesWeb,
        listedSearchAddress: SiteSearchListService.instance
            .addressFor(widget.webViewModel.initUrl),
        // Writes straight to the model: domain claims are not part of the
        // dirty snapshot and are saved as they are edited.
        domainClaims: DomainClaimsEditor(
          model: widget.webViewModel,
          otherSites: widget.otherSites,
          onChanged: (next) => widget.webViewModel.domainClaims = next,
        ),
        onChanged: (values) => setState(() {
          _alwaysOpenHome = values.alwaysOpenHome;
          _kioskMode = values.kioskMode;
          _fullscreenMode = values.fullscreenMode;
          _tabsEnabled = values.tabsEnabled;
          _htmlCachingEnabled = values.htmlCachingEnabled;
          _externalLinkMode = values.externalLinkMode;
          _routeOutboundLinks = values.routeOutboundLinks;
          _outboundPreferences = values.outboundPreferences;
          _searchAddress = values.searchAddress;
          _searchesWeb = values.searchesWeb;
          _searchSites = values.searchSites;
          _searchDefault = values.searchDefault.stored;
        }),
      ));

  SiteNetworkValues get _networkValues => SiteNetworkValues(
        proxyType: _proxySettings.type,
        torExitCountry: _proxySettings.torExitCountry,
        savedProxyId: _proxySettings.savedProxyId,
        gatewayId: _proxySettings.gatewayId,
        credentialsId: _proxySettings.credentialsId,
        webRtcPolicy: _webRtcPolicy,
      );

  /// Follows Behaviour: like it, this is how the app carries the site rather
  /// than what the site may do. The subtitle names the route the traffic
  /// takes, so whether the site is proxied is answered without opening it.
  Widget _buildNetworkRow() {
    final loc = AppLocalizations.of(context);
    final v = _networkValues;
    final proxied =
        PlatformInfo.isProxySupported && v.proxyType != ProxyType.DEFAULT;
    // DEFAULT means "no proxy of my own", and such a site goes through the
    // app-wide one when that is set (resolveEffectiveProxy). Reading it as
    // unproxied would answer the row's one question wrongly.
    final appProxySet = GlobalOutboundProxy.current.type != ProxyType.DEFAULT;
    final inheritsAppProxy = PlatformInfo.isProxySupported &&
        v.proxyType == ProxyType.DEFAULT &&
        appProxySet;
    // Named as the site will run it, so a Default that Tracking Protection
    // raises to Relay only reads as Relay only (ETP-031).
    final webRtc = resolveWebRtcPolicy(
      stored: v.webRtcPolicy,
      trackingProtectionEnabled: _trackingProtectionEnabled,
      proxied: v.proxyType != ProxyType.DEFAULT || appProxySet,
    );
    final address = _proxyAddressController.text.trim();
    final pin = v.torExitCountry?.trim() ?? '';
    final exitCountry = pin.isEmpty
        ? null
        : (torExitCountryFor(pin)?.label ?? pin.toUpperCase());

    // A proxy type, an address and a country are data, not translatable copy
    // (LOC-002).
    final on = <String>[
      if (inheritsAppProxy) loc.networkSummaryAppProxy,
      // A saved proxy or gateway goes by its name; one that no longer
      // resolves says why, since the site is blocked until it is fixed
      // (PROXY-030).
      if (proxied &&
          (v.proxyType == ProxyType.SAVED || v.proxyType == ProxyType.GATEWAY))
        libraryRouteLabel(loc, route: _proxySettings)
      else if (proxied)
        v.proxyType == ProxyType.TOR
            ? torRouteLabel(loc)
            : address.isEmpty
                ? v.proxyType.name
                : '${v.proxyType.name} $address',
      if (proxied && v.proxyType == ProxyType.TOR && exitCountry != null)
        exitCountry,
      ?webRtc.summary(loc),
    ];
    return SummaryNavRow(
      leading: const Icon(Icons.lan_outlined),
      title: loc.networkTitle,
      summary: summariseSettings(
        loc,
        on: on,
        none: loc.networkSummaryDefault,
      ),
      onTap: _openNetwork,
    );
  }

  Future<void> _openNetwork() => _push((_) => SiteNetworkScreen(
        host: widget.webViewModel.currentUrl,
        siteId: widget.webViewModel.siteId,
        values: _networkValues,
        proxySupported: PlatformInfo.isProxySupported,
        proxyAddressController: _proxyAddressController,
        proxyUsernameController: _proxyUsernameController,
        proxyPasswordController: _proxyPasswordController,
        proxyTest: ProxyTestTile(
          settings: _formProxy,
          target: proxyTestTarget(widget.webViewModel.initUrl),
          siteId: widget.webViewModel.siteId,
        ),
        showSavedSignIns: !widget.webViewModel.isArchiveTier,
        trackingProtectionEnabled: _trackingProtectionEnabled,
        appProxySet: GlobalOutboundProxy.current.type != ProxyType.DEFAULT,
        onChanged: (values) => setState(() {
          _proxySettings.type = values.proxyType;
          _proxySettings.torExitCountry = values.torExitCountry;
          _proxySettings.savedProxyId = values.savedProxyId;
          _proxySettings.gatewayId = values.gatewayId;
          _proxySettings.credentialsId = values.credentialsId;
          _webRtcPolicy = values.webRtcPolicy;
        }),
      ));

  SitePrivacyValues get _privacyValues => SitePrivacyValues(
        archived: _archived,
        trackingProtectionEnabled: _trackingProtectionEnabled,
        clearUrlEnabled: _clearUrlEnabled,
        dnsBlockEnabled: _dnsBlockEnabled,
        dnsBlockLevel: Scoped.fromStored(_dnsBlockLevel),
        contentBlockEnabled: _contentBlockEnabled,
        disabledFilterLists: _disabledFilterLists,
        localCdnEnabled: _localCdnEnabled,
        thirdPartyCookiesEnabled: _thirdPartyCookiesEnabled,
        httpsUpgrade: Scoped.fromStored(_httpsUpgradeEnabled),
        letterboxEnabled: _letterboxEnabled,
        incognito: _incognito,
        blockScreenshots: _blockScreenshots,
      );

  /// Counterpart of [_buildPermissionsRow] for everything that decides what a
  /// site can learn or keep. The subtitle answers the same question without
  /// opening the screen: what is actually on.
  Widget _buildPrivacyRow() {
    final loc = AppLocalizations.of(context);
    final v = _privacyValues;
    return SummaryNavRow(
      leading: Icon(v.trackingProtectionEnabled
          ? Icons.verified_user
          : Icons.verified_user_outlined),
      title: loc.privacyTitle,
      summary: summariseSettings(
        loc,
        on: v.trackingProtectionEnabled
            ? [loc.privacySummaryProtectionOn]
            : [
                if (v.effectiveClearUrl) loc.siteSettingsClearUrls,
                if (v.effectiveDnsBlock) loc.siteSettingsDnsBlocklist,
                if (v.effectiveContentBlock) loc.siteSettingsContentBlocker,
                if (hostIsAndroid && v.effectiveLocalCdn) loc.siteSettingsLocalCdn,
                if (v.effectiveIncognito) loc.siteSettingsIncognito,
                if (ScreenCaptureGuard.isSupported && v.effectiveBlockScreenshots)
                  loc.siteSettingsBlockScreenshots,
              ],
        none: loc.privacySummaryNothingOn,
      ),
      onTap: _openPrivacy,
    );
  }

  Future<void> _openPrivacy() => _push((_) => SitePrivacyScreen(
        host: widget.webViewModel.currentUrl,
        siteId: widget.webViewModel.siteId,
        values: _privacyValues,
        onChanged: (values) => setState(() {
          _trackingProtectionEnabled = values.trackingProtectionEnabled;
          _clearUrlEnabled = values.clearUrlEnabled;
          _dnsBlockEnabled = values.dnsBlockEnabled;
          _dnsBlockLevel = values.dnsBlockLevel.stored;
          _contentBlockEnabled = values.contentBlockEnabled;
          _disabledFilterLists = values.disabledFilterLists;
          _localCdnEnabled = values.localCdnEnabled;
          _thirdPartyCookiesEnabled = values.thirdPartyCookiesEnabled;
          _httpsUpgradeEnabled = values.httpsUpgrade.stored;
          _letterboxEnabled = values.letterboxEnabled;
          _incognito = values.incognito;
          _blockScreenshots = values.blockScreenshots;
        }),
      ));

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
IconButton setUserAgent(IconData icon,
        {required String tooltip, required String Function() ua}) =>
    IconButton(
      onPressed: () => setState(() => _userAgentController.text = ua()),
      icon: Icon(icon),
      tooltip: tooltip,
      color: Theme.of(context).colorScheme.primary,
      iconSize: 24,
    );
IconButton zoomStep(IconData icon,
        {required String tooltip, required int step, required bool enabled}) =>
    IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: enabled
          ? () => setState(
              () => _zoomPercent = clampZoomPercent(_zoomPercent + step))
          : null,
    );
    final zoomLabel = '$_zoomPercent%';
    return guardPop(
      child: Scaffold(
      appBar: AppBar(title: Text(loc.siteSettingsTitle)),
      body: ListView(
        children: [
          SettingsSection(loc.siteSettingsSectionContent),
          SettingTile(
            title: loc.siteSettingsJavascriptEnabled,
            hint: null,
            control: Toggle(_javascriptEnabled,
                onChanged: (value) => setState(() => _javascriptEnabled = value)),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              setUserAgent(Icons.home, tooltip: loc.siteSettingsUserAgentResetTooltip,
                  ua: () => ''),
              Expanded(
                child: TextFormField(
                  decoration: InputDecoration(
                    labelText: loc.siteSettingsUserAgent,
                    hintText: (widget.webViewModel.defaultUserAgent
                                ?.isNotEmpty ??
                            false)
                        ? widget.webViewModel.defaultUserAgent
                        : loc.siteSettingsUserAgentSystemDefault,
                    helperText: loc.siteSettingsUserAgentEmptyHelper,
                  ),
                  controller: _userAgentController,
                ),
              ),
              SizedBox(width: 8),
              setUserAgent(Icons.autorenew,
                  tooltip: loc.siteSettingsUserAgentRandomTooltip, ua: generateRandomUserAgent),
            ],
          ),
          _buildUserAgentIdentity(loc),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: DropdownButtonFormField<String?>(
              value: _selectedLanguage,
              decoration: InputDecoration(
                labelText: loc.siteSettingsLanguage,
                helperText: loc.siteSettingsLanguageHelper,
                border: const OutlineInputBorder(),
              ),
              items: [
                for (final MapEntry(:key, :value) in _languages)
                  DropdownMenuItem<String?>(
                    value: key,
                    child: Text(
                        key == null ? loc.siteSettingsLanguageSystemDefault : value),
                  ),
              ],
              onChanged: (value) => setState(() => _selectedLanguage = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 0.0),
            child: Row(
              children: [
                Expanded(child: Text(loc.siteSettingsPageZoom)),
                zoomStep(Icons.remove, tooltip: loc.siteSettingsZoomOut, step: -10,
                    enabled: _zoomPercent > kMinZoomPercent),
                GestureDetector(
                  onTap: () =>
                      setState(() => _zoomPercent = kDefaultZoomPercent),
                  child: SizedBox(
                    width: 56,
                    child: Text(
                      zoomLabel,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
                zoomStep(Icons.add, tooltip: loc.siteSettingsZoomIn, step: 10,
                    enabled: _zoomPercent < kMaxZoomPercent),
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
              label: zoomLabel,
              onChanged: (value) => setState(() =>
                  _zoomPercent = clampZoomPercent((value / 10).round() * 10)),
            ),
          ),
          SettingTile(
            title: loc.siteSettingsUserScripts,
            hint: null,
            subtitle: _userScriptsSubtitle(),
            control: Opens(() {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => UserScriptsScreen(
                    title: 'User Scripts',
                    userScripts: widget.webViewModel.userScripts,
                    onSave: (scripts) =>
                        widget.webViewModel.userScripts = scripts,
                    globalUserScripts: widget.globalUserScripts,
                    onGlobalUserScriptsChanged: widget.onGlobalUserScriptsChanged,
                    enabledGlobalScriptIds: widget.webViewModel.enabledGlobalScriptIds,
                    onEnabledGlobalScriptIdsChanged: (ids) =>
                        widget.webViewModel.enabledGlobalScriptIds = ids,
                    proxy: widget.webViewModel.outboundProxySettings,
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
            }),
          ),
          SettingsSection(loc.siteSettingsSectionSite),
          _buildBehaviourRow(),
          _buildNetworkRow(),
          _buildPrivacyRow(),
          _buildPermissionsRow(),
          const SizedBox(height: 8),
          if (widget.onClearCookies != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Builder(builder: (context) {
                final (label, dialogBody, snack) = widget.useContainers
                    ? (loc.siteSettingsClearSiteData, loc.siteSettingsClearSiteDataBody,
                        loc.siteSettingsClearSiteDataDone)
                    : (loc.siteSettingsClearCookies, loc.siteSettingsClearCookiesBody,
                        loc.siteSettingsClearCookiesDone);
                return OutlinedButton.icon(
                  icon: Icon(Icons.cookie, color: Colors.red),
                  label: Text(label, style: TextStyle(color: Colors.red)),
                  style: OutlinedButton.styleFrom(side: BorderSide(color: Colors.red)),
                  onPressed: () async {
                    if (!await confirm(
                      context,
                      title: label,
                      body: dialogBody,
                      confirmLabel: loc.siteSettingsClearConfirm,
                      destructive: true,
                    )) {
                      return;
                    }
                    widget.onClearCookies!();
                    if (mounted) ScaffoldMessenger.of(context).toast(snack);
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
                  model: widget.webViewModel,
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
  if (!hostIsIOS && !hostIsAndroid) return;
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_kBgNotifInfoShownPrefKey) == true) return;
  if (!context.mounted) return;
  final loc = AppLocalizations.of(context);
  final (title, body) = hostIsIOS
      ? (loc.siteSettingsBgNotifTitleIos, loc.siteSettingsBgNotifBodyIos)
      : (loc.siteSettingsBgNotifTitleAndroid, loc.siteSettingsBgNotifBodyAndroid);
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
