import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/theme/app_theme.dart';
import 'package:webspace/screens/app_appearance.dart';
import 'package:webspace/screens/app_backup.dart';
import 'package:webspace/screens/app_behaviour.dart';
import 'package:webspace/screens/app_developer.dart';
import 'package:webspace/screens/app_network.dart';
import 'package:webspace/screens/app_privacy.dart';
import 'package:webspace/screens/user_scripts.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/developer_unlock_engine.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/ubo_backup_import.dart';
import 'package:webspace/settings/app_locale.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/search_site_picker.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/toast.dart';

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
  /// LIR-008: entry into the routing overview screen.
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
    with SettingsOpenGuard, RebuildOnAppPref {
  /// The theme the Appearance screen last set, for its row's summary. The
  /// rest of the summaries read app prefs, which [RebuildOnAppPref] follows.
  late AppThemeSettings _settings = widget.currentSettings;

  /// `version+build` from the platform package, null until it resolves.
  String? _appVersion;
  /// Running tap count on the version row; the developer-options gesture.
  int _versionTaps = 0;
  bool get _developerMode => DeveloperModeService.instance.enabled;
  /// Held while the seventh tap is turning developer mode on, so taps landing
  /// during that await neither count nor unlock a second time.
  final _unlocking = ReentryGuard();

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (mounted) setState(() => _appVersion = '${info.version}+${info.buildNumber}');
    });
  }

  /// One tap on the version row: the Android developer-options gesture, which
  /// is the only entry point to [DeveloperModeService]. Diagnostic
  /// affordances (the Repaint Screen menu entry) are useless to an ordinary
  /// user and confusing to meet by accident, but a user reporting a bug has
  /// to be able to reach them without a debug build.
  Future<void> _onVersionTapped() async {
    if (_unlocking.busy) return;
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
        await _unlocking.run(() => setDeveloperMode(on: true));
        if (!mounted) return;
        setState(() => _versionTaps = 0);
        message = loc.appSettingsDeveloperModeEnabled;
    }
    if (!mounted) return;
    // Replace rather than queue: taps arrive faster than a snackbar's life, so
    // queueing would leave the countdown showing a number several taps stale.
    ScaffoldMessenger.of(context).toast(
      message,
      duration: const Duration(seconds: 1),
      replace: true,
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
        if (mounted) setState(() {});
      });

  /// Export, import and the archive actions run on the main page, so settings
  /// closes before each one.
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

  String _appearanceSummary(AppLocalizations loc) => [
        themeModeLabel(loc, mode: _settings.themeMode),
        if (AppPref.appLocaleOverride.value case final tag
            when tag.isNotEmpty)
          languageLabelForTag(tag),
      ].join(' · ');

  String _behaviourSummary(AppLocalizations loc) => summariseSettings(
        loc,
        on: [
          if (TabStrip.current != TabStrip.hidden) loc.appSettingsSiteTabStrip,
          if (AppPref.fullscreenOnShortcut.value)
            loc.appSettingsFullscreenOnShortcut,
          if (backOpensMenuOffered() && AppPref.backOpensMenu.value)
            loc.appSettingsBackOpensMenu,
          if (AppPref.linkHandlingEnabled.value) loc.appSettingsLinkHandling,
        ],
        none: loc.behaviourSummaryNothingOn,
      );

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
            onTap: () => _open(AppAppearanceScreen(
              settings: _settings,
              onSettingsChanged: (settings) {
                // The screen sits above this one, but the callback can still
                // land after both were torn down.
                if (mounted) setState(() => _settings = settings);
                widget.onSettingsChanged(settings);
              },
            )),
          ),
          SummaryNavRow(
            leading: const Icon(Icons.tune),
            title: loc.appSettingsBehaviour,
            summary: _behaviourSummary(loc),
            onTap: () => _open(AppBehaviourScreen(
              onOpenLinkHandlingSettings: widget.onOpenLinkHandlingSettings,
              webSearchSites: widget.webSearchSites,
            )),
          ),
          SettingsSection(loc.appSettingsGroupSites),
          SummaryNavRow(
            leading: const Icon(Icons.lan_outlined),
            title: loc.appSettingsNetwork,
            summary: appNetworkSummary(loc),
            onTap: () => _open(AppNetworkScreen(
              siteNames: widget.siteNames,
              onOutboundProxyChanged: widget.onOutboundProxyChanged,
              siteProxies: widget.siteProxies,
              onSavedProxiesChanged: widget.onSavedProxiesChanged,
            )),
          ),
          SummaryNavRow(
            leading: const Icon(Icons.verified_user_outlined),
            title: loc.appSettingsPrivacy,
            summary: summariseSettings(
              loc,
              on: appPrivacyOn(loc),
              none: loc.privacySummaryNothingOn,
            ),
            onTap: () => _open(AppPrivacyScreen(
              siteNames: widget.siteNames,
              onTrustUboHosts: widget.onTrustUboHosts,
            )),
          ),
          SummaryNavRow(
            leading: const Icon(Icons.code),
            title: loc.appSettingsUserScripts,
            summary: widget.globalUserScripts.isEmpty
                ? loc.appSettingsNoGlobalScripts
                : loc.appSettingsScriptsDefined(widget.globalUserScripts.length),
            onTap: () => _open(UserScriptsScreen(
              title: 'Global User Scripts',
              userScripts: widget.globalUserScripts,
              onSave: (scripts) =>
                  widget.onGlobalUserScriptsChanged?.call(scripts),
              isGlobalLibrary: true,
            )),
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
                on: experimentsOn(loc,
                    proxyRouterRunsHere: widget.proxyRouterRunsHere),
                none: loc.behaviourSummaryNothingOn,
              ),
              onTap: () => _open(AppDeveloperScreen(
                proxyRouterRunsHere: widget.proxyRouterRunsHere,
                externalTorRunsHere: widget.externalTorRunsHere,
              )),
            )
          else
            SettingTile(
              leading: const Icon(Icons.article_outlined),
              title: loc.appSettingsAppLogs,
              hint: null,
              subtitle: loc.appSettingsAppLogsSubtitle,
              control: Trailing(null,
                  onTap: () => guardedOpen(() => openAppLogs(context))),
            ),
          SettingTile(
            leading: const Icon(Icons.info_outline),
            title: loc.appSettingsLicenses,
            hint: null,
            subtitle: loc.appSettingsLicensesSubtitle,
            control: Trailing(null, onTap: () => guardedOpen(() async {
              final packageInfo = await PackageInfo.fromPlatform();
              if (!context.mounted) return;
              showLicensePage(
                context: context,
                applicationName: 'WebSpace',
                applicationVersion: packageInfo.version,
                applicationLegalese: '© 2023 Kirill Rodriguez',
              );
            })),
          ),
          SettingTile(
            leading: const Icon(Icons.tag),
            title: loc.appSettingsVersion,
            hint: null,
            subtitle: _appVersion,
            control: Trailing(null, onTap: _onVersionTapped),
          ),
        ],
      ),
    );
  }
}
