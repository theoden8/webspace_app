import 'dart:async';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/screens/dev_tools.dart';
import 'package:webspace/services/content_rule_lists.dart';
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/toast.dart';

/// Opens the app logs, which every user can reach to report a bug.
Future<void> openAppLogs(BuildContext context,
        {bool startOnBackground = false}) =>
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (context) => DevToolsScreen(
          startOnBackground: startOnBackground,
        ),
      ),
    );

/// The experiments this device offers, in the order the Experimental group
/// lists them.
List<(ExperimentalFeature, IconData, String title, String hint)> _experiments(
        AppLocalizations loc,
        {required bool proxyRouterRunsHere}) =>
    [
      (ExperimentalFeature.folderLibrary, Icons.apps_rounded,
          loc.appSettingsExperimentalFolderLibrary,
          loc.appSettingsExperimentalFolderLibraryHint),
      if (proxyRouterRunsHere)
        (ExperimentalFeature.proxyRouter, Icons.hub_outlined,
            loc.appSettingsExperimentalProxyRouter,
            loc.appSettingsExperimentalProxyRouterHint),
      if (hostIsAndroid)
        (ExperimentalFeature.textureRendering, Icons.layers_outlined,
            loc.appSettingsExperimentalTextureRendering,
            loc.appSettingsExperimentalTextureRenderingHint),
      if (MethodChannelContentRuleListStore.here != null)
        (ExperimentalFeature.contentRuleLists, Icons.shield_outlined,
            loc.appSettingsExperimentalContentRuleLists,
            loc.appSettingsExperimentalContentRuleListsHint),
    ];

/// The names of the experiments switched on, for the App Settings row.
List<String> experimentsOn(AppLocalizations loc,
        {required bool proxyRouterRunsHere}) =>
    [
      for (final (feature, _, title, _)
          in _experiments(loc, proxyRouterRunsHere: proxyRouterRunsHere))
        if (ExperimentalFeaturesService.instance.switchOn(feature)) title,
    ];

/// Developer mode's own screen: the switch that turns it off, the logs, and
/// the Experimental group (DEVTOOLS-011). Reached only while developer mode
/// is on; App Settings links the app logs directly otherwise.
class AppDeveloperScreen extends StatefulWidget {
  const AppDeveloperScreen({
    super.key,
    this.proxyRouterRunsHere = false,
  });

  /// Whether this device could run the per-site proxy router, so the
  /// Experimental group lists its switch (DEVTOOLS-011). Passed in because
  /// the answer needs the container engine the app resolved at startup.
  final bool proxyRouterRunsHere;

  @override
  State<AppDeveloperScreen> createState() => _AppDeveloperScreenState();
}

class _AppDeveloperScreenState extends State<AppDeveloperScreen>
    with SettingsOpenGuard, RebuildOnAppPref {
  /// Set once the switch is flipped off, so a second flip during the await
  /// neither turns it off again nor pops a second route.
  bool _turningOff = false;

  /// Off leaves the screen: everything on it but the logs belongs to
  /// developer mode, and App Settings links the logs on its own.
  Future<void> _turnOff() async {
    if (_turningOff) return;
    setState(() => _turningOff = true);
    await DeveloperModeService.instance.setEnabled(on: false);
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

  Future<void> _resetIconCache() async {
    final messenger = ScaffoldMessenger.of(context);
    final cleared = AppLocalizations.of(context).appSettingsIconCacheCleared;
    await FaviconUrlCache.resetAll();
    messenger.toast(cleared);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.appSettingsDeveloper)),
      body: ListView(
        children: [
          SettingTile(
            leading: const Icon(Icons.developer_mode),
            title: loc.appSettingsDeveloperMode,
            hint: loc.appSettingsDeveloperModeHint,
            lock: _turningOff ? const Lock.because(null) : null,
            control: Toggle(!_turningOff, onChanged: (value) {
              if (!value) unawaited(_turnOff());
            }),
          ),
          SettingsSection(loc.devToolsTabLogs),
          SettingTile(
            leading: const Icon(Icons.article_outlined),
            title: loc.appSettingsAppLogs,
            hint: null,
            subtitle: loc.appSettingsAppLogsSubtitle,
            control: Trailing(null,
                onTap: () => guardedOpen(() => openAppLogs(context))),
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
          // Alternative design runs on every platform, so the group always has a
          // row.
          SettingsSection(
            loc.appSettingsExperimental,
            hint: loc.appSettingsExperimentalHint,
          ),
          for (final (feature, icon, title, hint) in _experiments(loc,
              proxyRouterRunsHere: widget.proxyRouterRunsHere))
            SettingTile(
              leading: Icon(icon),
              title: title,
              hint: hint,
              control: Toggle(
                ExperimentalFeaturesService.instance.switchOn(feature),
                onChanged: (value) => ExperimentalFeaturesService.instance
                    .setSwitch(feature, on: value),
              ),
            ),
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
