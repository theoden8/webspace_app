import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/icon_service.dart'
    show notifyIconSourcesChanged;
import 'package:webspace/services/tor_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/widgets/external_tor_tiles.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';

/// Turns developer mode on or off, with everything it decides.
Future<void> setDeveloperMode(bool value) async {
  await DeveloperModeService.instance.setEnabled(value);
  notifyIconSourcesChanged();
  // The external tor is an experiment, so developer mode decides it too.
  await TorService.instance.runtimeChoiceChanged();
}

/// Opens the app logs, which every user can reach to report a bug.
Future<void> openAppLogs(BuildContext context,
        {bool startOnBackground = false}) =>
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => DevToolsScreen(
          cookieManager: CookieManager(),
          startOnBackground: startOnBackground,
        ),
      ),
    );

/// The names of the experiments switched on, for the App Settings row.
List<String> experimentsOn(AppLocalizations loc,
        {required bool proxyRouterRunsHere}) =>
    [
      if (proxyRouterRunsHere &&
          ExperimentalFeaturesService.instance
              .switchOn(ExperimentalFeature.proxyRouter))
        loc.appSettingsExperimentalProxyRouter,
      if (ExperimentalFeaturesService.instance
          .switchOn(ExperimentalFeature.siteIconsOnly))
        loc.appSettingsExperimentalSiteIconsOnly,
      if (hostIsAndroid &&
          ExperimentalFeaturesService.instance
              .switchOn(ExperimentalFeature.textureRendering))
        loc.appSettingsExperimentalTextureRendering,
      if (ExperimentalFeaturesService.instance
          .switchOn(ExperimentalFeature.siteTabs))
        loc.appSettingsExperimentalSiteTabs,
    ];

/// Developer mode's own screen: the switch that turns it off, the logs, and
/// the Experimental group (DEVTOOLS-011). Reached only while developer mode
/// is on; App Settings links the app logs directly otherwise.
class AppDeveloperScreen extends StatefulWidget {
  const AppDeveloperScreen({
    super.key,
    this.proxyRouterRunsHere = false,
    this.externalTorRunsHere = false,
  });

  /// Whether this device could run the per-site proxy router, so the
  /// Experimental group lists its switch (DEVTOOLS-011). Passed in because
  /// the answer needs the container engine the app resolved at startup.
  final bool proxyRouterRunsHere;

  /// Whether Tor sites can use a tor already running on this device, so the
  /// Experimental group lists Tor (external) (TOR-025). Passed in so the
  /// design gallery, which runs on web, can show it.
  final bool externalTorRunsHere;

  @override
  State<AppDeveloperScreen> createState() => _AppDeveloperScreenState();
}

class _AppDeveloperScreenState extends State<AppDeveloperScreen>
    with SettingsOpenGuard {
  bool _proxyRouterSwitch = ExperimentalFeaturesService.instance
      .switchOn(ExperimentalFeature.proxyRouter);
  bool _siteIconsOnlySwitch = ExperimentalFeaturesService.instance
      .switchOn(ExperimentalFeature.siteIconsOnly);
  bool _textureRenderingSwitch = ExperimentalFeaturesService.instance
      .switchOn(ExperimentalFeature.textureRendering);
  bool _siteTabsSwitch = ExperimentalFeaturesService.instance
      .switchOn(ExperimentalFeature.siteTabs);

  /// Set once the switch is flipped off, so a second flip during the await
  /// neither turns it off again nor pops a second route.
  bool _turningOff = false;

  /// Off leaves the screen: everything on it but the logs belongs to
  /// developer mode, and App Settings links the logs on its own.
  Future<void> _turnOff() async {
    if (_turningOff) return;
    setState(() => _turningOff = true);
    await setDeveloperMode(false);
    if (!mounted) return;
    // Only this route: a logs screen opened during the await stays.
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  Future<void> _setProxyRouterSwitch(bool value) async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.proxyRouter, value);
    if (!mounted) return;
    setState(() => _proxyRouterSwitch = value);
  }

  Future<void> _setSiteIconsOnlySwitch(bool value) async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.siteIconsOnly, value);
    notifyIconSourcesChanged();
    if (!mounted) return;
    setState(() => _siteIconsOnlySwitch = value);
  }

  Future<void> _resetIconCache() async {
    final messenger = ScaffoldMessenger.of(context);
    final cleared = AppLocalizations.of(context).appSettingsIconCacheCleared;
    await FaviconUrlCache.resetAll();
    messenger.showSnackBar(SnackBar(content: Text(cleared)));
  }

  Future<void> _setTextureRenderingSwitch(bool value) async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.textureRendering, value);
    if (!mounted) return;
    setState(() => _textureRenderingSwitch = value);
  }

  Future<void> _setSiteTabsSwitch(bool value) async {
    await ExperimentalFeaturesService.instance
        .setSwitch(ExperimentalFeature.siteTabs, value);
    if (!mounted) return;
    setState(() => _siteTabsSwitch = value);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsDeveloper)),
      body: ListView(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.developer_mode),
            title: HintedTitle(loc.appSettingsDeveloperMode,
                hint: loc.appSettingsDeveloperModeHint),
            value: !_turningOff,
            onChanged: _turningOff
                ? null
                : (value) {
                    if (!value) _turnOff();
                  },
          ),
          SettingsSection(loc.devToolsTabLogs),
          ListTile(
            leading: const Icon(Icons.article_outlined),
            title: Text(loc.appSettingsAppLogs),
            subtitle: Text(loc.appSettingsAppLogsSubtitle),
            onTap: () => guardedOpen(() => openAppLogs(context)),
          ),
          SettingTile(
            key: const Key('app-settings-background-log'),
            leading: const Icon(Icons.bedtime_outlined),
            title: loc.appSettingsBackgroundLog,
            hint: loc.appSettingsBackgroundLogHint,
            control: Trailing(null,
                onTap: () => guardedOpen(
                    () => openAppLogs(context, startOnBackground: true))),
          ),
          // Site tabs run on every platform, so the group always has a row.
          SettingsSection(
            loc.appSettingsExperimental,
            hint: loc.appSettingsExperimentalHint,
          ),
          if (widget.proxyRouterRunsHere)
            SettingTile(
              leading: const Icon(Icons.hub_outlined),
              title: loc.appSettingsExperimentalProxyRouter,
              hint: loc.appSettingsExperimentalProxyRouterHint,
              control: Toggle(_proxyRouterSwitch, _setProxyRouterSwitch),
            ),
          SettingTile(
            leading: const Icon(Icons.image_outlined),
            title: loc.appSettingsExperimentalSiteIconsOnly,
            hint: loc.appSettingsExperimentalSiteIconsOnlyHint,
            control: Toggle(_siteIconsOnlySwitch, _setSiteIconsOnlySwitch),
          ),
          if (hostIsAndroid)
            SettingTile(
              leading: const Icon(Icons.layers_outlined),
              title: loc.appSettingsExperimentalTextureRendering,
              hint: loc.appSettingsExperimentalTextureRenderingHint,
              control:
                  Toggle(_textureRenderingSwitch, _setTextureRenderingSwitch),
            ),
          SettingTile(
            leading: const Icon(Icons.tab_outlined),
            title: loc.appSettingsExperimentalSiteTabs,
            hint: loc.appSettingsExperimentalSiteTabsHint,
            control: Toggle(_siteTabsSwitch, _setSiteTabsSwitch),
          ),
          if (widget.externalTorRunsHere)
            ExternalTorTiles(onTorChanged: () {
              if (mounted) setState(() {});
            }),
          SettingTile(
            leading: const Icon(Icons.hide_image_outlined),
            title: loc.appSettingsResetIconCache,
            hint: loc.appSettingsResetIconCacheHint,
            control: Trailing(null, onTap: _resetIconCache),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
