import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/block_stats.dart';
import 'package:webspace/screens/content_blocker_settings.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/ubo_backup_import.dart';
import 'package:webspace/settings/datasets.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/widgets/dataset_tile.dart';
import 'package:webspace/widgets/level_slider.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';

/// The names of the app-wide protections that are on, for the App Settings
/// row. Same shape as the Privacy row in site settings.
List<String> appPrivacyOn(AppLocalizations loc) => [
      if (AppPref.httpsUpgradeEnabled.value) loc.siteSettingsHttpsUpgrade,
      if (DnsBlockService.instance.level > 0) loc.appSettingsDnsBlocklist,
      if (ContentBlockerService.instance.lists.any((l) => l.enabled))
        loc.appSettingsContentBlocker,
      if (hostIsAndroid && LocalCdnService.instance.resourceCount > 0)
        loc.appSettingsLocalCdn,
      if (ScreenCaptureGuard.isSupported && AppPref.blockScreenshots.value)
        loc.siteSettingsBlockScreenshots,
    ];

/// What every site may learn or keep: the app-wide blockers each site's own
/// Privacy screen masks, the identity data its spoofing draws on, and screen
/// capture.
class AppPrivacyScreen extends StatefulWidget {
  const AppPrivacyScreen({
    super.key,
    this.siteNames = const {},
    this.onTrustUboHosts,
  });

  /// `siteId` -> display name, passed through to the protection report so its
  /// per-category drill-down can name the sites a block was recorded for.
  final Map<String, String> siteNames;

  /// See [ContentBlockerSettingsScreen.onTrustUboHosts].
  final Future<List<UboTrustedSite>> Function(Set<String> hosts,
      {required bool apply})? onTrustUboHosts;

  @override
  State<AppPrivacyScreen> createState() => _AppPrivacyScreenState();
}

class _AppPrivacyScreenState extends State<AppPrivacyScreen>
    with SettingsOpenGuard {
  final _osmTileUrlController =
      TextEditingController(text: AppPref.osmTileUrl.value);

  @override
  void dispose() {
    _osmTileUrlController.dispose();
    super.dispose();
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
          SettingTile(
            leading: const Icon(Icons.shield_outlined),
            title: loc.blockStatsTitle,
            hint: null,
            subtitle: loc.appSettingsProtectionReportSubtitle,
            control: Opens(() => guardedOpen(() => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (context) =>
                        BlockStatsScreen(siteNames: widget.siteNames),
                  ),
                ))),
          ),
          SettingTile(
            title: loc.appSettingsStatsBar,
            hint: null,
            subtitle: loc.appSettingsStatsBarSubtitle,
            control: const PrefToggle(AppPref.showStatsBanner),
          ),
          SettingsSection(loc.privacyGroupTrackers),
          SettingTile(
            title: loc.siteSettingsHttpsUpgrade,
            hint: loc.siteSettingsHttpsUpgradeHint,
            control: const PrefToggle(AppPref.httpsUpgradeEnabled),
          ),
          DatasetTile(
            create: ClearUrlsDataset.new,
            icon: Icons.cleaning_services,
            title: loc.appSettingsClearUrlsRules,
            hint: loc.appSettingsClearUrlsHint,
          ),
          DatasetTile(
            create: DnsBlocklistDataset.new,
            icon: Icons.shield,
            title: loc.appSettingsDnsBlocklist,
            hint: loc.appSettingsDnsBlocklistHint,
            below: (dns, download) => LevelSlider(
              labels: dnsBlockLevelNames,
              value: dns.picked,
              onChanged: download == null ? null : dns.pick,
            ),
          ),
          SettingTile(
            leading: const Icon(Icons.filter_list),
            title: loc.appSettingsContentBlocker,
            hint: loc.appSettingsContentBlockerHint,
            subtitle: summariseSettings(loc, enabledLists,
                none: loc.appSettingsNotConfigured),
            control: Opens(() => guardedOpen(_openContentBlocker)),
          ),
          if (hostIsAndroid)
            DatasetTile(
              create: LocalCdnDataset.new,
              icon: Icons.storage,
              title: loc.appSettingsLocalCdn,
              hint: loc.appSettingsLocalCdnHint,
            ),
          SettingsSection(loc.appSettingsGroupWhatSitesLearn),
          DatasetTile(
            create: FirefoxVersionDataset.new,
            icon: Icons.travel_explore,
            title: loc.appSettingsFirefoxVersion,
            hint: '${loc.appSettingsFirefoxVersionHint}\n\n'
                '${loc.appSettingsFirefoxAutoUpdate}: '
                '${loc.appSettingsFirefoxAutoUpdateHint}',
            below: (firefox, download) => SwitchListTile(
              // start: the title column. end: 24 puts the switch track flush
              // with the refresh icon above it, which sits inset in its
              // button.
              contentPadding:
                  const EdgeInsetsDirectional.only(start: 72, end: 24),
              dense: true,
              visualDensity: VisualDensity.compact,
              title: Text(loc.appSettingsFirefoxAutoUpdate,
                  style: const TextStyle(fontSize: 13)),
              value: firefox.autoRefresh,
              onChanged: (value) async {
                await firefox.setAutoRefresh(value);
                // Enabling is itself the user gesture: run the first check
                // right away instead of waiting for the next startup.
                if (value) download?.call();
              },
            ),
          ),
          DatasetTile(
            create: TimezoneDataset.new,
            icon: Icons.public,
            title: loc.appSettingsTimezonePolygons,
            hint: loc.appSettingsTimezonePolygonsHint,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: HintedTitle(
              loc.appSettingsLocationPicker,
              hint: loc.appSettingsLocationPickerHint,
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: TextFormField(
              controller: _osmTileUrlController,
              decoration: InputDecoration(
                labelText: loc.appSettingsTileUrl,
                hintText: AppPref.osmTileUrl.fallback,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (value) {
                final url = value.trim();
                AppPref.osmTileUrl
                    .set(url.isEmpty ? AppPref.osmTileUrl.fallback : url);
              },
            ),
          ),
          if (ScreenCaptureGuard.isSupported) ...[
            SettingsSection(loc.privacyGroupScreenCapture),
            SettingTile(
              leading: const Icon(Icons.no_photography_outlined),
              title: loc.siteSettingsBlockScreenshots,
              hint: loc.appSettingsBlockScreenshotsHint,
              control: const PrefToggle(AppPref.blockScreenshots),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
