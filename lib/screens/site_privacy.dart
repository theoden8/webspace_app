import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/site_overrides.dart';
import 'package:webspace/services/webview.dart' show WebViewFactory;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/settings/setting_labels.dart';
import 'package:webspace/widgets/level_slider.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/stat_chip.dart';

/// Everything the privacy screen may change, in one value so the caller can
/// apply a whole edit in a single `setState`.
///
/// Same contract as `SitePermissionValues`: [SiteSettingsScreen] keeps the
/// fields, the dirty-snapshot diff and the save path, and this is only a
/// different way of presenting them. Moving the fields here would take them
/// out of that diff, which is how unsaved edits get dropped (BUG-006).
class SitePrivacyValues {
  const SitePrivacyValues({
    required this.archived,
    required this.trackingProtectionEnabled,
    required this.clearUrlEnabled,
    required this.dnsBlockEnabled,
    this.dnsBlockLevel = const FollowApp(),
    required this.contentBlockEnabled,
    this.disabledFilterLists = const <String>{},
    required this.localCdnEnabled,
    required this.thirdPartyCookiesEnabled,
    this.httpsUpgrade = const FollowApp(),
    required this.letterboxEnabled,
    required this.incognito,
    this.blockScreenshots = false,
  });

  /// Not edited here: an archive-tier site runs with the archive's posture
  /// for the settings ARCH-006 folds.
  final bool archived;
  final bool trackingProtectionEnabled;
  final bool clearUrlEnabled;
  final bool dnsBlockEnabled;
  final Scoped<int> dnsBlockLevel;
  final bool contentBlockEnabled;

  /// Filter list ids this site opts out of.
  final Set<String> disabledFilterLists;
  final bool localCdnEnabled;
  final bool thirdPartyCookiesEnabled;
  final Scoped<bool> httpsUpgrade;
  final bool letterboxEnabled;
  final bool incognito;
  final bool blockScreenshots;

  SitePrivacyValues copyWith({
    bool? trackingProtectionEnabled,
    bool? clearUrlEnabled,
    bool? dnsBlockEnabled,
    Scoped<int>? dnsBlockLevel,
    Scoped<bool>? httpsUpgrade,
    bool? contentBlockEnabled,
    Set<String>? disabledFilterLists,
    bool? localCdnEnabled,
    bool? thirdPartyCookiesEnabled,
    bool? letterboxEnabled,
    bool? incognito,
    bool? blockScreenshots,
  }) =>
      SitePrivacyValues(
        archived: archived,
        trackingProtectionEnabled:
            trackingProtectionEnabled ?? this.trackingProtectionEnabled,
        clearUrlEnabled: clearUrlEnabled ?? this.clearUrlEnabled,
        dnsBlockEnabled: dnsBlockEnabled ?? this.dnsBlockEnabled,
        dnsBlockLevel: dnsBlockLevel ?? this.dnsBlockLevel,
        httpsUpgrade: httpsUpgrade ?? this.httpsUpgrade,
        contentBlockEnabled: contentBlockEnabled ?? this.contentBlockEnabled,
        disabledFilterLists: disabledFilterLists ?? this.disabledFilterLists,
        localCdnEnabled: localCdnEnabled ?? this.localCdnEnabled,
        thirdPartyCookiesEnabled:
            thirdPartyCookiesEnabled ?? this.thirdPartyCookiesEnabled,
        letterboxEnabled: letterboxEnabled ?? this.letterboxEnabled,
        incognito: incognito ?? this.incognito,
        blockScreenshots: blockScreenshots ?? this.blockScreenshots,
      );

  bool _forced(TrackingProtectionForce force, bool stored) =>
      force.resolve(stored, trackingProtection: trackingProtectionEnabled);

  bool get effectiveClearUrl =>
      _forced(TrackingProtectionForce.clearUrls, clearUrlEnabled);
  bool get effectiveDnsBlock =>
      _forced(TrackingProtectionForce.dnsBlock, dnsBlockEnabled);
  bool get effectiveContentBlock =>
      _forced(TrackingProtectionForce.contentBlock, contentBlockEnabled);
  bool get effectiveLocalCdn => ArchiveFold.localCdn(
      _forced(TrackingProtectionForce.localCdn, localCdnEnabled),
      archived: archived);
  bool get effectiveThirdPartyCookies => _forced(
      TrackingProtectionForce.thirdPartyCookies, thirdPartyCookiesEnabled);
  bool get effectiveHttpsUpgrade => _forced(TrackingProtectionForce.httpsUpgrade,
      httpsUpgrade.resolve(WebViewFactory.httpsUpgradeEnabled));
  bool get effectiveIncognito =>
      ArchiveFold.incognito(incognito, archived: archived);

  /// The archive drops the per-site level, which would pin a level file on
  /// disk outside its keyspace.
  int? get effectiveDnsBlockLevel =>
      ArchiveFold.dnsBlockLevel(dnsBlockLevel.stored, archived: archived);

  /// The app-wide switch covers every site (SCREENBLOCK-002).
  bool get effectiveBlockScreenshots =>
      blockScreenshots || AppPref.blockScreenshots.value;
}

/// Per-site privacy screen: the tracking-protection umbrella, the settings it
/// forces, and the storage posture that decides what survives a session.
class SitePrivacyScreen extends StatefulWidget {
  const SitePrivacyScreen({
    super.key,
    required this.host,
    required this.siteId,
    required this.values,
    required this.onChanged,
  });

  final String host;

  /// Keys the per-site DNS counters shown under the blocklist row.
  final String siteId;

  final SitePrivacyValues values;
  final ValueChanged<SitePrivacyValues> onChanged;

  @override
  State<SitePrivacyScreen> createState() => _SitePrivacyScreenState();
}

class _SitePrivacyScreenState extends State<SitePrivacyScreen> {
  late SitePrivacyValues _values = widget.values;

  /// Level whose list is being fetched right now, so the row can show it is
  /// working rather than looking like the pick did nothing.
  int? _downloadingLevel;

  void _update(SitePrivacyValues next) {
    setState(() => _values = next);
    widget.onChanged(next);
  }

  /// Shown when the user enables a blocker whose backing data (DNS blocklist,
  /// filter lists) hasn't been downloaded: the toggle still flips and takes
  /// effect once the data arrives, but silently doing nothing until then
  /// would read as the feature being broken.
  void _warnNotConfigured(String feature) {
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(loc.siteSettingsBlockerNotConfiguredWarning(feature)),
      ),
    );
  }

  Lock? _umbrella(TrackingProtectionForce force) =>
      _values.trackingProtectionEnabled
          ? TrackingProtectionLock(forcedTo: force.forcedTo)
          : null;

  // --- Umbrella ------------------------------------------------------------

  Widget _trackingProtectionCard(AppLocalizations loc) {
    final scheme = Theme.of(context).colorScheme;
    final on = _values.trackingProtectionEnabled;
    final unconfigured = on &&
        (!DnsBlockService.instance.hasBlocklist ||
            !ContentBlockerService.instance.hasRules);
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: on ? scheme.secondaryContainer : null,
      child: SwitchListTile(
        secondary: Icon(
          on ? Icons.verified_user : Icons.verified_user_outlined,
          color: on ? scheme.onSecondaryContainer : null,
        ),
        title: HintedTitle(
          loc.siteSettingsTrackingProtection,
          hint: loc.siteSettingsTrackingProtectionHint,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          warn: unconfigured,
        ),
        subtitle: Text(loc.siteSettingsTrackingProtectionSubtitle,
            style: const TextStyle(fontSize: 12.5)),
        value: on,
        onChanged: (value) {
          if (value) {
            final missing = <String>[
              if (!DnsBlockService.instance.hasBlocklist)
                loc.siteSettingsDnsBlocklist,
              if (!ContentBlockerService.instance.hasRules)
                loc.siteSettingsContentBlocker,
            ];
            if (missing.isNotEmpty) _warnNotConfigured(missing.join(', '));
          }
          _update(_values.copyWith(trackingProtectionEnabled: value));
        },
      ),
    );
  }

  // --- Trackers ------------------------------------------------------------

  Widget _clearUrls(AppLocalizations loc) => SettingTile(
        title: loc.siteSettingsClearUrls,
        hint: loc.siteSettingsClearUrlsHint,
        subtitle: loc.siteSettingsClearUrlsSubtitle,
        lock: _umbrella(TrackingProtectionForce.clearUrls),
        control: Toggle(_values.effectiveClearUrl,
            (value) => _update(_values.copyWith(clearUrlEnabled: value))),
      );

  Widget _dnsBlocklist(AppLocalizations loc) {
    final ready = DnsBlockService.instance.hasBlocklist;
    return SettingTile(
      title: loc.siteSettingsDnsBlocklist,
      hint: loc.siteSettingsDnsBlocklistHint,
      missingData: _values.effectiveDnsBlock && !ready,
      subtitle: ready
          ? dnsBlockLevelNames[_effectiveDnsLevel]
          : loc.siteSettingsNotConfigured,
      lock: _umbrella(TrackingProtectionForce.dnsBlock),
      control: Toggle(_values.effectiveDnsBlock, (value) {
        if (value && !ready) _warnNotConfigured(loc.siteSettingsDnsBlocklist);
        _update(_values.copyWith(dnsBlockEnabled: value));
      }),
    );
  }

  Widget _contentBlocker(AppLocalizations loc) {
    final ready = ContentBlockerService.instance.hasRules;
    return SettingTile(
      title: loc.siteSettingsContentBlocker,
      hint: loc.siteSettingsContentBlockerHint,
      missingData: _values.effectiveContentBlock && !ready,
      subtitle: ready
          ? loc.siteSettingsContentBlockerRuleCount(
              ContentBlockerService.instance.totalRuleCount)
          : loc.siteSettingsNotConfigured,
      lock: _umbrella(TrackingProtectionForce.contentBlock),
      control: Toggle(_values.effectiveContentBlock, (value) {
        if (value && !ready) _warnNotConfigured(loc.siteSettingsContentBlocker);
        _update(_values.copyWith(contentBlockEnabled: value));
      }),
    );
  }

  /// Severity level the site's DNS checks actually run at.
  int get _effectiveDnsLevel => DnsBlockService.instance
      .effectiveLevelFor(_values.effectiveDnsBlockLevel);

  bool get _dnsLevelNeedsDownload => dnsLevelNeedsDownload(
        siteLevel: _values.effectiveDnsBlockLevel,
        downloadedLevels: DnsBlockService.instance.downloadedLevels,
      );

  /// Slider stop standing for "same as app settings". The stops above it are
  /// the levels themselves; level 0 (Off) is not one of them, because the
  /// row's own switch is what turns DNS blocking off.
  static const int _followsAppStop = 0;

  /// Rows that refine the one above them sit indented under it.
  static const EdgeInsets _nested = EdgeInsets.only(left: 32, right: 16);

  Widget _dnsBlocklistLevel(AppLocalizations loc) {
    final needsDownload = _dnsLevelNeedsDownload;
    final chosen = _values.dnsBlockLevel;
    final title = loc.siteSettingsDnsBlocklistLevel;
    final subtitle = needsDownload
        ? loc.siteSettingsDnsLevelNeedsDownload(
            dnsBlockLevelNames[_effectiveDnsLevel])
        : switch (chosen) {
            FollowApp() => loc.siteSettingsDnsLevelFollowsApp(
                dnsBlockLevelNames[DnsBlockService.instance.level]),
            Own(:final value) => dnsBlockLevelNames[value],
          };
    return Column(
      children: [
        SettingTile(
          contentPadding: _nested,
          title: title,
          hint: loc.siteSettingsDnsBlocklistLevelHint,
          missingData: needsDownload,
          subtitle: subtitle,
          lock: _values.archived ? const ArchiveLock() : null,
          control: Trailing(_downloadingLevel == null
              ? null
              : const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))),
        ),
        LevelSlider(
          padding: _nested,
          labels: [
            loc.siteSettingsDnsLevelFollowAppShort,
            for (var level = 1; level <= kDnsMaxLevel; level++)
              dnsBlockLevelNames[level],
          ],
          value: switch (chosen) {
            FollowApp() => _followsAppStop,
            Own(:final value) => value,
          },
          onChanged: _downloadingLevel != null || _values.archived
              ? null
              : (stop) => _update(_values.copyWith(
                    dnsBlockLevel:
                        stop == _followsAppStop ? const FollowApp() : Own(stop),
                  )),
          // Fetching waits for the drag to settle: every stop the thumb
          // crosses is a level, and downloading each one would pull four
          // lists nobody asked for.
          onChangeEnd: (stop) {
            if (stop != _followsAppStop &&
                !DnsBlockService.instance.downloadedLevels.contains(stop)) {
              _downloadLevel(stop);
            }
          },
        ),
      ],
    );
  }

  /// Fetch a level's list on demand. Until it lands the site keeps running at
  /// the app-wide level — the tier boundary it asked for does not exist yet,
  /// and evaluating against the tiers anyway would block nothing.
  Future<void> _downloadLevel(int level) async {
    setState(() => _downloadingLevel = level);
    _snack(AppLocalizations.of(context).siteSettingsDnsLevelDownloading);
    final ok = await DnsBlockService.instance.downloadLevel(level);
    if (!mounted) return;
    setState(() => _downloadingLevel = null);
    if (!ok) _snack(AppLocalizations.of(context).siteSettingsDnsLevelDownloadFailed);
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Widget _contentBlockerLists(AppLocalizations loc) {
    final available =
        ContentBlockerService.instance.lists.where((l) => l.enabled).toList();
    if (available.isEmpty) return const SizedBox.shrink();
    final off = ArchiveFold.disabledFilterLists(_values.disabledFilterLists,
        archived: _values.archived);
    final onCount = available.where((l) => !off.contains(l.id)).length;
    return SettingTile(
      contentPadding: _nested,
      title: loc.siteSettingsContentBlockerLists,
      hint: loc.siteSettingsContentBlockerListsHint,
      subtitle:
          loc.siteSettingsContentBlockerListsSubtitle(onCount, available.length),
      lock: _values.archived ? const ArchiveLock() : null,
      control: Opens(() => _pickFilterLists(available)),
    );
  }

  Future<void> _pickFilterLists(List<FilterList> available) async {
    final loc = AppLocalizations.of(context);
    final off = {..._values.disabledFilterLists};
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(loc.siteSettingsContentBlockerLists),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final list in available)
                  CheckboxListTile(
                    value: !off.contains(list.id),
                    title: Text(list.name),
                    onChanged: (on) => setDialogState(() {
                      if (on ?? false) {
                        off.remove(list.id);
                      } else {
                        off.add(list.id);
                      }
                    }),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(loc.commonDone),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    _update(_values.copyWith(disabledFilterLists: off));
  }

  Widget _localCdn(AppLocalizations loc) {
    final hasCache = LocalCdnService.instance.hasCache;
    return SettingTile(
      title: loc.siteSettingsLocalCdn,
      hint: loc.siteSettingsLocalCdnHint,
      subtitle: loc.siteSettingsLocalCdnResourceCount(
          LocalCdnService.instance.resourceCount),
      lock: !hasCache
          ? NotDownloadedLock(loc.siteSettingsLocalCdnNeedsCache)
          : _values.archived
              ? const ArchiveLock()
              : _umbrella(TrackingProtectionForce.localCdn),
      control: Toggle(_values.effectiveLocalCdn && hasCache,
          (value) => _update(_values.copyWith(localCdnEnabled: value))),
    );
  }

  Widget _thirdPartyCookies(AppLocalizations loc) => SettingTile(
        title: loc.siteSettingsThirdPartyCookies,
        hint: loc.siteSettingsThirdPartyCookiesHint,
        subtitle: loc.siteSettingsThirdPartyCookiesSubtitle,
        lock: _umbrella(TrackingProtectionForce.thirdPartyCookies),
        control: Toggle(_values.effectiveThirdPartyCookies,
            (value) => _update(_values.copyWith(thirdPartyCookiesEnabled: value))),
      );

  /// Follows App Settings until the site picks its own value, and can go
  /// back to following (HTTPS-005).
  Widget _httpsUpgrade(AppLocalizations loc) {
    final appValue = WebViewFactory.httpsUpgradeEnabled;
    return ChoiceTile<Scoped<bool>>(
      title: loc.siteSettingsHttpsUpgrade,
      hint: loc.siteSettingsHttpsUpgradeHint,
      lock: _umbrella(TrackingProtectionForce.httpsUpgrade),
      values: const [FollowApp(), Own(true), Own(false)],
      label: (choice) => choice.label(loc, appValue: appValue),
      value: _values.trackingProtectionEnabled
          ? const Own(true)
          : _values.httpsUpgrade,
      onChanged: (choice) => _update(_values.copyWith(httpsUpgrade: choice)),
    );
  }

  // --- Fingerprinting ------------------------------------------------------

  Widget _letterbox(AppLocalizations loc) => SettingTile(
        title: loc.siteSettingsLetterboxTitle,
        hint: loc.siteSettingsWindowSizeHelper,
        lock: _values.trackingProtectionEnabled
            ? null
            : RequiresLock(loc.siteSettingsNeedsTrackingProtection),
        control: Toggle(
            _values.letterboxEnabled && _values.trackingProtectionEnabled,
            (value) => _update(_values.copyWith(letterboxEnabled: value))),
      );

  // --- Storage -------------------------------------------------------------

  /// Sits above the umbrella, not under it. Incognito is the bluntest thing
  /// on the screen (nothing survives the session at all), and unlike the
  /// blockers it costs the user their own logins, so it stays their call.
  Widget _incognitoCard(AppLocalizations loc) {
    final scheme = Theme.of(context).colorScheme;
    final on = _values.effectiveIncognito;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      color: on ? scheme.secondaryContainer : null,
      child: SwitchListTile(
        secondary: Icon(
          on ? Icons.visibility_off : Icons.visibility_off_outlined,
          color: on ? scheme.onSecondaryContainer : null,
        ),
        title: Text(
          loc.siteSettingsIncognito,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        subtitle: Text(
            _values.archived
                ? loc.settingLockedByArchive
                : loc.siteSettingsIncognitoSubtitle,
            style: const TextStyle(fontSize: 12.5)),
        value: on,
        onChanged: _values.archived
            ? null
            : (value) => _update(_values.copyWith(incognito: value)),
      ),
    );
  }

  // --- Screen capture ------------------------------------------------------

  Widget _blockScreenshots(AppLocalizations loc) => SettingTile(
        title: loc.siteSettingsBlockScreenshots,
        hint: loc.siteSettingsBlockScreenshotsHint,
        lock: AppPref.blockScreenshots.value
            ? AppWideLock(loc.siteSettingsBlockScreenshotsAppWide)
            : null,
        control: Toggle(_values.effectiveBlockScreenshots,
            (value) => _update(_values.copyWith(blockScreenshots: value))),
      );

  // --- DNS counters --------------------------------------------------------

  Widget _dnsStats() {
    final stats = DnsBlockService.instance.statsForSite(widget.siteId);
    if (stats.total == 0) return const SizedBox.shrink();
    return DnsStatChips(stats,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4));
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.privacyTitle)),
      body: ListView(
        children: [
          SettingsNote.host(widget.host),
          _incognitoCard(loc),
          _trackingProtectionCard(loc),
          SettingsSection(loc.privacyGroupTrackers),
          _clearUrls(loc),
          _dnsBlocklist(loc),
          if (_values.effectiveDnsBlock && DnsBlockService.instance.hasBlocklist)
            _dnsBlocklistLevel(loc),
          if (DnsBlockService.instance.hasBlocklist) _dnsStats(),
          _contentBlocker(loc),
          if (_values.effectiveContentBlock &&
              ContentBlockerService.instance.hasRules)
            _contentBlockerLists(loc),
          if (hostIsAndroid) _localCdn(loc),
          _thirdPartyCookies(loc),
          _httpsUpgrade(loc),
          SettingsSection(loc.privacyGroupFingerprinting),
          _letterbox(loc),
          // Only while the umbrella is on: with it off nothing is being
          // randomised, and the note would be describing something that is
          // not happening.
          if (_values.trackingProtectionEnabled)
            SettingsNote(loc.privacyFingerprintingNote),
          if (ScreenCaptureGuard.isSupported) ...[
            SettingsSection(loc.privacyGroupScreenCapture),
            _blockScreenshots(loc),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
