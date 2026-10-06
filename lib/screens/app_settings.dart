import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/main.dart' show AppThemeSettings;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/app_appearance.dart';
import 'package:webspace/screens/app_backup.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/app_developer.dart';
import 'package:webspace/screens/app_network.dart';
import 'package:webspace/screens/app_privacy.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/services/back_gesture_engine.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/developer_unlock_engine.dart';
import 'package:webspace/services/ubo_backup_import.dart';
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/search_site_picker.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';

/// App Settings: an index of categories, each a screen of its own, like the
/// Site rows in site settings. Every row says what its category is set to.
class AppSettingsScreen extends StatefulWidget {
  final AppThemeSettings currentSettings;

  /// Whether this device could run the per-site proxy router, so the
  /// Experimental group lists its switch (DEVTOOLS-011). Passed in because
  /// the answer needs the container engine the app resolved at startup.
  final bool proxyRouterRunsHere;

  /// Whether Tor sites can use a tor already running on this device, so the
  /// Experimental group lists Tor (external) (TOR-025). Passed in so the
  /// design gallery, which runs on web, can show it.
  final bool externalTorRunsHere;
  final Function(AppThemeSettings) onSettingsChanged;
  final VoidCallback onExportSettings;
  final VoidCallback onImportSettings;

  /// Finds the app-tier sites a uBlock Origin backup trusts (content
  /// blocker on, not held on by Tracking Protection) and, with `apply`,
  /// switches their content blocker off and saves. A callback rather than
  /// the models themselves: the sites stay owned by the page.
  final Future<List<UboTrustedSite>> Function(Set<String> hosts,
      {required bool apply})? onTrustUboHosts;
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
  final bool fullscreenOnShortcut;
  final ValueChanged<bool> onFullscreenOnShortcutChanged;
  /// NAV-009: back gesture opens the drawer where a site has no page left to
  /// go back to (and leaves the app on the press after that). Off by default.
  final bool backOpensMenu;
  final ValueChanged<bool> onBackOpensMenuChanged;
  final bool tabBarButton;
  final ValueChanged<bool> onTabBarButtonChanged;
  final int tabMaxWidth;
  final ValueChanged<int> onTabMaxWidthChanged;
  final bool showStatsBanner;
  final ValueChanged<bool> onShowStatsBannerChanged;
  /// HTTPS-005: app-wide default for retrying a plain-http navigation over
  /// https. A site can override it; Tracking Protection forces it on.
  final bool httpsUpgradeEnabled;
  final ValueChanged<bool> onHttpsUpgradeEnabledChanged;
  /// SCREENBLOCK-002: withhold the whole app from screen capture.
  final bool blockScreenshots;
  final ValueChanged<bool>? onBlockScreenshotsChanged;
  /// Current UI language override as a locale tag ('' = follow system).
  final String localeOverride;
  final ValueChanged<String> onLocaleOverrideChanged;
  /// LIR-008: master "Handle shared links" switch + entry into the
  /// routing overview screen. The wrapping page handles persistence.
  final bool linkHandlingEnabled;
  final ValueChanged<bool> onLinkHandlingEnabledChanged;
  final VoidCallback onOpenLinkHandlingSettings;

  /// The user's web search sites outside every archive (LIR-029), each with
  /// its container's colour, null on the legacy engine.
  final List<PickableSearchSite> webSearchSites;
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

  /// Every site's proxy setting, so the proxy library can say what uses each
  /// entry (PROXY-030).
  final List<UserProxySettings> Function()? siteProxies;

  /// Fired after the proxy library was edited. Same duty as
  /// [onOutboundProxyChanged]: a webview bound to a saved proxy's old
  /// configuration keeps routing through it until it is rebuilt.
  final VoidCallback? onSavedProxiesChanged;
  /// `siteId` -> display name, passed through to the protection report so its
  /// per-category drill-down can name the sites a block was recorded for.
  final Map<String, String> siteNames;

  const AppSettingsScreen({
    super.key,
    required this.currentSettings,
    this.proxyRouterRunsHere = false,
    this.externalTorRunsHere = false,
    this.siteNames = const {},
    required this.onSettingsChanged,
    required this.onExportSettings,
    required this.onImportSettings,
    this.onTrustUboHosts,
    this.onRestoreArchive,
    this.hasOpenArchives = false,
    this.onCloseAllArchives,
    required this.showTabStrip,
    required this.onShowTabStripChanged,
    required this.tabStripInFullscreen,
    required this.onTabStripInFullscreenChanged,
    required this.fullscreenOnShortcut,
    required this.onFullscreenOnShortcutChanged,
    required this.backOpensMenu,
    required this.onBackOpensMenuChanged,
    required this.tabBarButton,
    required this.onTabBarButtonChanged,
    required this.tabMaxWidth,
    required this.onTabMaxWidthChanged,
    required this.showStatsBanner,
    required this.onShowStatsBannerChanged,
    required this.httpsUpgradeEnabled,
    required this.onHttpsUpgradeEnabledChanged,
    this.blockScreenshots = false,
    this.onBlockScreenshotsChanged,
    required this.localeOverride,
    required this.onLocaleOverrideChanged,
    required this.linkHandlingEnabled,
    required this.onLinkHandlingEnabledChanged,
    required this.onOpenLinkHandlingSettings,
    this.webSearchSites = const [],
    this.globalUserScripts = const [],
    this.onGlobalUserScriptsChanged,
    this.onOutboundProxyChanged,
    this.siteProxies,
    this.onSavedProxiesChanged,
  });

  @override
  State<AppSettingsScreen> createState() => _AppSettingsScreenState();
}

class _AppSettingsScreenState extends State<AppSettingsScreen>
    with SettingsOpenGuard {
  // Copies of what the category screens change, kept current through their
  // callbacks so the row summaries answer without reopening them.
  late AppThemeSettings _settings = widget.currentSettings;
  late String _localeOverride = widget.localeOverride;
  late bool _showTabStrip = widget.showTabStrip;
  late bool _tabStripInFullscreen = widget.tabStripInFullscreen;
  late bool _tabBarButton = widget.tabBarButton;
  late int _tabMaxWidth = widget.tabMaxWidth;
  late bool _fullscreenOnShortcut = widget.fullscreenOnShortcut;
  late bool _backOpensMenu = widget.backOpensMenu;
  late bool _showStatsBanner = widget.showStatsBanner;
  late bool _httpsUpgradeEnabled = widget.httpsUpgradeEnabled;
  late bool _blockScreenshots = widget.blockScreenshots;

  /// `version+build` from the platform package, null until it resolves.
  String? _appVersion;
  /// Running tap count on the version row; the developer-options gesture.
  int _versionTaps = 0;
  bool _developerMode = DeveloperModeService.instance.enabled;
  /// Set while the seventh tap is turning developer mode on, so taps landing
  /// during that await neither count nor unlock a second time.
  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (!mounted) return;
    setState(() => _appVersion = '${info.version}+${info.buildNumber}');
  }

  /// One tap on the version row: the Android developer-options gesture, which
  /// is the only entry point to [DeveloperModeService]. Diagnostic
  /// affordances (the Repaint Screen menu entry) are useless to an ordinary
  /// user and confusing to meet by accident, but a user reporting a bug has
  /// to be able to reach them without a debug build.
  Future<void> _onVersionTapped() async {
    if (_unlocking) return;
    final loc = AppLocalizations.of(context);
    final step = DeveloperUnlockEngine.tap(
      taps: _versionTaps,
      enabled: _developerMode,
    );
    setState(() => _versionTaps = step.taps);
    String? message;
    switch (step.outcome) {
      case DeveloperUnlockOutcome.silent:
        return;
      case DeveloperUnlockOutcome.countdown:
        message = loc.appSettingsDeveloperModeStepsAway(step.remaining);
      case DeveloperUnlockOutcome.alreadyEnabled:
        message = loc.appSettingsDeveloperModeAlreadyOn;
      case DeveloperUnlockOutcome.unlocked:
        _unlocking = true;
        try {
          await setDeveloperMode(true);
        } finally {
          _unlocking = false;
        }
        if (!mounted) return;
        setState(() {
          _developerMode = true;
          _versionTaps = 0;
        });
        message = loc.appSettingsDeveloperModeEnabled;
    }
    if (!mounted) return;
    // Replace rather than queue: taps arrive faster than a snackbar's life, so
    // queueing would leave the countdown showing a number several taps stale.
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 1)),
      );
  }

  /// Opens a category and, once it closes, redraws the summaries from what it
  /// changed. One at a time: a second tap while the first is still sliding
  /// in would stack a second copy.
  Future<void> _open(Widget screen) => guardedOpen(() async {
        await Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => screen),
        );
        if (!mounted) return;
        setState(() => _developerMode = DeveloperModeService.instance.enabled);
      });

  /// Keeps a summary current from a category screen's callback. The screen
  /// sits above this one, but an async callback can still land after both
  /// were torn down.
  void _track(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  void _openAppearance() => _open(AppAppearanceScreen(
        settings: _settings,
        onSettingsChanged: (settings) {
          _track(() => _settings = settings);
          widget.onSettingsChanged(settings);
        },
        localeOverride: _localeOverride,
        onLocaleOverrideChanged: (tag) {
          _track(() => _localeOverride = tag);
          widget.onLocaleOverrideChanged(tag);
        },
      ));

  void _openBehaviour() => _open(AppBehaviourScreen(
        showTabStrip: _showTabStrip,
        onShowTabStripChanged: (value) {
          _track(() => _showTabStrip = value);
          widget.onShowTabStripChanged(value);
        },
        tabStripInFullscreen: _tabStripInFullscreen,
        onTabStripInFullscreenChanged: (value) {
          _track(() => _tabStripInFullscreen = value);
          widget.onTabStripInFullscreenChanged(value);
        },
        tabBarButton: _tabBarButton,
        onTabBarButtonChanged: (value) {
          _track(() => _tabBarButton = value);
          widget.onTabBarButtonChanged(value);
        },
        tabMaxWidth: _tabMaxWidth,
        onTabMaxWidthChanged: (value) {
          _track(() => _tabMaxWidth = value);
          widget.onTabMaxWidthChanged(value);
        },
        fullscreenOnShortcut: _fullscreenOnShortcut,
        onFullscreenOnShortcutChanged: (value) {
          _track(() => _fullscreenOnShortcut = value);
          widget.onFullscreenOnShortcutChanged(value);
        },
        backOpensMenu: _backOpensMenu,
        onBackOpensMenuChanged: (value) {
          _track(() => _backOpensMenu = value);
          widget.onBackOpensMenuChanged(value);
        },
        linkHandlingEnabled: widget.linkHandlingEnabled,
        onOpenLinkHandlingSettings: widget.onOpenLinkHandlingSettings,
        webSearchSites: widget.webSearchSites,
      ));

  void _openNetwork() => _open(AppNetworkScreen(
        siteNames: widget.siteNames,
        onOutboundProxyChanged: widget.onOutboundProxyChanged,
        siteProxies: widget.siteProxies,
        onSavedProxiesChanged: widget.onSavedProxiesChanged,
      ));

  void _openPrivacy() => _open(AppPrivacyScreen(
        siteNames: widget.siteNames,
        showStatsBanner: _showStatsBanner,
        onShowStatsBannerChanged: (value) {
          _track(() => _showStatsBanner = value);
          widget.onShowStatsBannerChanged(value);
        },
        httpsUpgradeEnabled: _httpsUpgradeEnabled,
        onHttpsUpgradeEnabledChanged: (value) {
          _track(() => _httpsUpgradeEnabled = value);
          widget.onHttpsUpgradeEnabledChanged(value);
        },
        blockScreenshots: _blockScreenshots,
        onBlockScreenshotsChanged: widget.onBlockScreenshotsChanged == null
            ? null
            : (value) {
                _track(() => _blockScreenshots = value);
                widget.onBlockScreenshotsChanged!(value);
              },
        onTrustUboHosts: widget.onTrustUboHosts,
      ));

  void _openUserScripts() => _open(UserScriptsScreen(
        title: 'Global User Scripts',
        userScripts: widget.globalUserScripts,
        onSave: (scripts) {
          widget.onGlobalUserScriptsChanged?.call(scripts);
        },
        isGlobalLibrary: true,
      ));

  void _openDeveloper() => _open(AppDeveloperScreen(
        proxyRouterRunsHere: widget.proxyRouterRunsHere,
        externalTorRunsHere: widget.externalTorRunsHere,
      ));

  /// Export, import and the archive actions run on the main page, so settings
  /// closes before each one, as it did when they were rows of their own.
  Future<void> _openBackup() => guardedOpen(() async {
        final action = await Navigator.push<AppBackupAction>(
          context,
          MaterialPageRoute(
            builder: (_) => AppBackupScreen(
              offerRestoreArchive: widget.onRestoreArchive != null,
              offerCloseAllArchives:
                  widget.hasOpenArchives && widget.onCloseAllArchives != null,
            ),
          ),
        );
        if (action == null || !mounted) return;
        _closeSelf();
        _runBackupAction(action);
      });

  /// Leaves settings for the main page. Pops only this route: if anything
  /// was pushed above it in the meantime, a plain pop would close that
  /// instead and leave settings open under the action.
  void _closeSelf() {
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (route.isCurrent) {
      navigator.pop();
    } else {
      navigator.removeRoute(route);
    }
  }

  void _runBackupAction(AppBackupAction action) {
    switch (action) {
      case AppBackupAction.export:
        widget.onExportSettings();
      case AppBackupAction.import:
        widget.onImportSettings();
      case AppBackupAction.restoreArchive:
        widget.onRestoreArchive?.call();
      case AppBackupAction.closeAllArchives:
        widget.onCloseAllArchives?.call();
    }
  }

  String _appearanceSummary(AppLocalizations loc) => [
        themeModeLabel(loc, _settings.themeMode),
        if (_localeOverride.isNotEmpty) languageLabelForTag(_localeOverride),
      ].join(' · ');

  String _behaviourSummary(AppLocalizations loc) {
    final backOpensMenuOffered = backAtHistoryStartConfigurable(
      isIOS: hostIsIOS,
      isMacOS: hostIsMacOS,
    );
    return summariseSettings(
      loc,
      [
        if (TabStrip.of(
                showTabStrip: _showTabStrip, tabBarButton: _tabBarButton) !=
            TabStrip.hidden)
          loc.appSettingsSiteTabStrip,
        if (_fullscreenOnShortcut) loc.appSettingsFullscreenOnShortcut,
        if (backOpensMenuOffered && _backOpensMenu)
          loc.appSettingsBackOpensMenu,
        if (widget.linkHandlingEnabled) loc.appSettingsLinkHandling,
      ],
      none: loc.behaviourSummaryNothingOn,
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(loc.appSettingsTitle),
      ),
      body: ListView(
        children: [
          SettingsSection(loc.appSettingsGroupApp),
          SummaryNavRow(
            leading: const Icon(Icons.palette_outlined),
            title: loc.appSettingsAppearance,
            summary: _appearanceSummary(loc),
            onTap: _openAppearance,
          ),
          SummaryNavRow(
            leading: const Icon(Icons.tune),
            title: loc.appSettingsBehaviour,
            summary: _behaviourSummary(loc),
            onTap: _openBehaviour,
          ),
          SettingsSection(loc.appSettingsGroupSites),
          SummaryNavRow(
            leading: const Icon(Icons.lan_outlined),
            title: loc.appSettingsNetwork,
            summary: appNetworkSummary(loc),
            onTap: _openNetwork,
          ),
          SummaryNavRow(
            leading: const Icon(Icons.verified_user_outlined),
            title: loc.appSettingsPrivacy,
            summary: summariseSettings(
              loc,
              appPrivacyOn(
                loc,
                httpsUpgradeEnabled: _httpsUpgradeEnabled,
                blockScreenshots: _blockScreenshots,
              ),
              none: loc.privacySummaryNothingOn,
            ),
            onTap: _openPrivacy,
          ),
          SummaryNavRow(
            leading: const Icon(Icons.code),
            title: loc.appSettingsUserScripts,
            summary: widget.globalUserScripts.isEmpty
                ? loc.appSettingsNoGlobalScripts
                : loc.appSettingsScriptsDefined(widget.globalUserScripts.length),
            onTap: _openUserScripts,
          ),
          SettingsSection(loc.appSettingsData),
          SummaryNavRow(
            leading: const Icon(Icons.settings_backup_restore),
            title: loc.appSettingsBackupAndArchives,
            summary: null,
            onTap: _openBackup,
          ),
          SettingsSection(loc.appSettingsAbout),
          // Next to the version row whose taps turn it on.
          if (_developerMode)
            SummaryNavRow(
              leading: const Icon(Icons.developer_mode),
              title: loc.appSettingsDeveloper,
              summary: summariseSettings(
                loc,
                experimentsOn(loc,
                    proxyRouterRunsHere: widget.proxyRouterRunsHere),
                none: loc.behaviourSummaryNothingOn,
              ),
              onTap: _openDeveloper,
            )
          else
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(loc.appSettingsAppLogs),
              subtitle: Text(loc.appSettingsAppLogsSubtitle),
              onTap: () => guardedOpen(() => openAppLogs(context)),
            ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(loc.appSettingsLicenses),
            subtitle: Text(loc.appSettingsLicensesSubtitle),
            onTap: () => guardedOpen(() async {
              final packageInfo = await PackageInfo.fromPlatform();
              if (!context.mounted) return;
              showLicensePage(
                context: context,
                applicationName: 'WebSpace',
                applicationVersion: packageInfo.version,
                applicationLegalese: '© 2023 Kirill Rodriguez',
              );
            }),
          ),
          ListTile(
            leading: const Icon(Icons.tag),
            title: Text(loc.appSettingsVersion),
            subtitle: _appVersion == null ? null : Text(_appVersion!),
            onTap: _onVersionTapped,
          ),
        ],
      ),
    );
  }
}
