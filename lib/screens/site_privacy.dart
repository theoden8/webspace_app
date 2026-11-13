import 'dart:async';

import 'package:webspace/settings/filter_list_id.dart';
import 'package:webspace/platform/apple_os_floor.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/screen_capture_guard.dart';
import 'package:webspace/services/site_overrides.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/scoped.dart';
import 'package:webspace/widgets/level_slider.dart';
import 'package:webspace/widgets/setting_tile.dart';
import 'package:webspace/widgets/settings_rows.dart';
import 'package:webspace/widgets/stat_chip.dart';
import 'package:webspace/widgets/toast.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/dirty_guard.dart' show ValueSet;

/// What a site stores of its privacy posture, the whole of what the privacy
/// screen edits. A record, so the settings screen's dirty snapshot compares
/// every field of it and a field added here cannot be left out of that
/// comparison, which is how unsaved edits got dropped (BUG-006).
typedef PrivacyChoices = ({
  bool trackingProtectionEnabled,
  bool clearUrlEnabled,
  bool dnsBlockEnabled,
  Scoped<int> dnsBlockLevel,
  bool contentBlockEnabled,
  /// Filter list ids this site opts out of.
  ValueSet<FilterListId> disabledFilterLists,
  bool localCdnEnabled,
  bool thirdPartyCookiesEnabled,
  Scoped<bool> httpsUpgrade,
  Scoped<bool> lockdownMode,
  bool letterboxEnabled,
  bool incognito,
  bool blockScreenshots,
  bool javascriptEnabled,
});

/// Where a site's [PrivacyChoices] are stored: the one mapping between the
/// record and the model's fields.
extension SitePrivacyChoices on WebViewModel {
  PrivacyChoices get privacyChoices => (
        trackingProtectionEnabled: trackingProtectionEnabled,
        clearUrlEnabled: clearUrlEnabled,
        dnsBlockEnabled: dnsBlockEnabled,
        dnsBlockLevel: Scoped.fromStored(dnsBlockLevel),
        contentBlockEnabled: contentBlockEnabled,
        disabledFilterLists: ValueSet(disabledFilterLists),
        localCdnEnabled: localCdnEnabled,
        thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
        httpsUpgrade: Scoped.fromStored(httpsUpgradeEnabled),
        lockdownMode: Scoped.fromStored(lockdownModeEnabled),
        letterboxEnabled: letterboxEnabled,
        incognito: incognito,
        blockScreenshots: blockScreenshots,
        javascriptEnabled: javascriptEnabled,
      );

  /// The pattern names every field, so one added to [PrivacyChoices] does
  /// not compile until it is stored here.
  set privacyChoices(PrivacyChoices c) {
    final (
      :trackingProtectionEnabled,
      :clearUrlEnabled,
      :dnsBlockEnabled,
      :dnsBlockLevel,
      :contentBlockEnabled,
      :disabledFilterLists,
      :localCdnEnabled,
      :thirdPartyCookiesEnabled,
      :httpsUpgrade,
      :lockdownMode,
      :letterboxEnabled,
      :incognito,
      :blockScreenshots,
      :javascriptEnabled,
    ) = c;
    this.trackingProtectionEnabled = trackingProtectionEnabled;
    this.clearUrlEnabled = clearUrlEnabled;
    this.dnsBlockEnabled = dnsBlockEnabled;
    this.dnsBlockLevel = dnsBlockLevel.stored;
    this.contentBlockEnabled = contentBlockEnabled;
    this.disabledFilterLists = {...disabledFilterLists.items};
    this.localCdnEnabled = localCdnEnabled;
    this.thirdPartyCookiesEnabled = thirdPartyCookiesEnabled;
    httpsUpgradeEnabled = httpsUpgrade.stored;
    lockdownModeEnabled = lockdownMode.stored;
    this.letterboxEnabled = letterboxEnabled;
    this.incognito = incognito;
    this.blockScreenshots = blockScreenshots;
    this.javascriptEnabled = javascriptEnabled;
  }
}

extension PrivacyChoicesEdit on PrivacyChoices {
  /// These choices with the given ones replaced.
  PrivacyChoices copyWith({
    bool? trackingProtectionEnabled,
    bool? clearUrlEnabled,
    bool? dnsBlockEnabled,
    Scoped<int>? dnsBlockLevel,
    bool? contentBlockEnabled,
    ValueSet<FilterListId>? disabledFilterLists,
    bool? localCdnEnabled,
    bool? thirdPartyCookiesEnabled,
    Scoped<bool>? httpsUpgrade,
    Scoped<bool>? lockdownMode,
    bool? letterboxEnabled,
    bool? incognito,
    bool? blockScreenshots,
    bool? javascriptEnabled,
  }) =>
      (
        trackingProtectionEnabled:
            trackingProtectionEnabled ?? this.trackingProtectionEnabled,
        clearUrlEnabled: clearUrlEnabled ?? this.clearUrlEnabled,
        dnsBlockEnabled: dnsBlockEnabled ?? this.dnsBlockEnabled,
        dnsBlockLevel: dnsBlockLevel ?? this.dnsBlockLevel,
        contentBlockEnabled: contentBlockEnabled ?? this.contentBlockEnabled,
        disabledFilterLists: disabledFilterLists ?? this.disabledFilterLists,
        localCdnEnabled: localCdnEnabled ?? this.localCdnEnabled,
        thirdPartyCookiesEnabled:
            thirdPartyCookiesEnabled ?? this.thirdPartyCookiesEnabled,
        httpsUpgrade: httpsUpgrade ?? this.httpsUpgrade,
        lockdownMode: lockdownMode ?? this.lockdownMode,
        letterboxEnabled: letterboxEnabled ?? this.letterboxEnabled,
        incognito: incognito ?? this.incognito,
        blockScreenshots: blockScreenshots ?? this.blockScreenshots,
        javascriptEnabled: javascriptEnabled ?? this.javascriptEnabled,
      );
}

/// The privacy screen's input: the site's [choices] and what they resolve to
/// where it runs.
class SitePrivacyValues {
  const SitePrivacyValues({required this.archived, required this.choices});

  /// Not edited here: an archive-tier site runs with the archive's posture
  /// for the settings ARCH-006 folds.
  final bool archived;
  final PrivacyChoices choices;

  SitePrivacyValues withChoices(PrivacyChoices next) =>
      SitePrivacyValues(archived: archived, choices: next);

  bool _forced(TrackingProtectionForce force, {required bool stored}) =>
      force.resolve(
          stored: stored, trackingProtection: choices.trackingProtectionEnabled);

  bool get effectiveClearUrl => _forced(TrackingProtectionForce.clearUrls,
      stored: choices.clearUrlEnabled);
  bool get effectiveDnsBlock => _forced(TrackingProtectionForce.dnsBlock,
      stored: choices.dnsBlockEnabled);
  bool get effectiveContentBlock =>
      _forced(TrackingProtectionForce.contentBlock,
          stored: choices.contentBlockEnabled);
  bool get effectiveLocalCdn => ArchiveFold.localCdn(
      stored: _forced(TrackingProtectionForce.localCdn,
          stored: choices.localCdnEnabled),
      archived: archived);
  bool get effectiveThirdPartyCookies =>
      _forced(TrackingProtectionForce.thirdPartyCookies,
          stored: choices.thirdPartyCookiesEnabled);
  bool get effectiveHttpsUpgrade => _forced(TrackingProtectionForce.httpsUpgrade,
      stored: choices.httpsUpgrade.resolve(AppPref.httpsUpgradeEnabled.value));
  bool get effectiveLockdownMode => resolveLockdownMode(
      choice: choices.lockdownMode,
      trackingProtection: choices.trackingProtectionEnabled);
  bool get effectiveIncognito =>
      ArchiveFold.incognito(stored: choices.incognito, archived: archived);

  /// The archive drops the per-site level, which would pin a level file on
  /// disk outside its keyspace.
  int? get effectiveDnsBlockLevel =>
      ArchiveFold.dnsBlockLevel(choices.dnsBlockLevel.stored,
          archived: archived);

  /// The app-wide switch covers every site (SCREENBLOCK-002).
  bool get effectiveBlockScreenshots =>
      choices.blockScreenshots || AppPref.blockScreenshots.value;
}

/// Per-site privacy screen: the tracking-protection umbrella, the settings it
/// forces, the storage posture that decides what survives a session, and
/// whether the site's pages run JavaScript at all.
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
  final SiteId siteId;

  final SitePrivacyValues values;
  final ValueChanged<SitePrivacyValues> onChanged;

  @override
  State<SitePrivacyScreen> createState() => _SitePrivacyScreenState();
}

class _SitePrivacyScreenState extends State<SitePrivacyScreen>
    with RebuildOnAppPref {
  late SitePrivacyValues _values = widget.values;

  /// Level whose list is being fetched right now, so the row can show it is
  /// working rather than looking like the pick did nothing.
  int? _downloadingLevel;

  PrivacyChoices get _choices => _values.choices;

  void _update(PrivacyChoices next) {
    setState(() => _values = _values.withChoices(next));
    widget.onChanged(_values);
  }

  /// Shown when the user enables a blocker whose backing data (DNS blocklist,
  /// filter lists) hasn't been downloaded: the toggle still flips and takes
  /// effect once the data arrives, but silently doing nothing until then
  /// would read as the feature being broken.
  void _warnNotConfigured(String feature) {
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).toast(
      loc.siteSettingsBlockerNotConfiguredWarning(feature),
    );
  }

  Lock? _umbrella(TrackingProtectionForce force) =>
      _choices.trackingProtectionEnabled
          ? TrackingProtectionLock(forcedTo: force.forcedTo)
          : null;

  // --- Umbrella ------------------------------------------------------------

  Widget _trackingProtectionCard(AppLocalizations loc) {
    final scheme = Theme.of(context).colorScheme;
    final on = _choices.trackingProtectionEnabled;
    List<String> missing() => [
          if (!DnsBlockService.instance.hasBlocklist)
            loc.siteSettingsDnsBlocklist,
          if (!ContentBlockerService.instance.hasRules)
            loc.siteSettingsContentBlocker,
        ];
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
          warn: on && missing().isNotEmpty,
        ),
        subtitle: Text(loc.siteSettingsTrackingProtectionSubtitle,
            style: const TextStyle(fontSize: 12.5)),
        value: on,
        onChanged: (value) {
          final unconfigured = missing();
          if (value && unconfigured.isNotEmpty) {
            _warnNotConfigured(unconfigured.join(', '));
          }
          _update(_choices.copyWith(trackingProtectionEnabled: value));
        },
      ),
    );
  }

  // --- Trackers ------------------------------------------------------------

  Widget _dnsBlocklist(AppLocalizations loc) {
    final ready = DnsBlockService.instance.hasBlocklist;
    return SettingTile(
      title: loc.siteSettingsDnsBlocklist,
      hint: loc.siteSettingsDnsBlocklistHint,
      missingData: _values.effectiveDnsBlock && !ready,
      subtitle: ready
          ? Localized.verbatim(dnsBlockLevelNames[_effectiveDnsLevel])
          : loc.siteSettingsNotConfigured,
      lock: _umbrella(TrackingProtectionForce.dnsBlock),
      control: Toggle(value: _values.effectiveDnsBlock, onChanged: (value) {
        if (value && !ready) _warnNotConfigured(loc.siteSettingsDnsBlocklist);
        _update(_choices.copyWith(dnsBlockEnabled: value));
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
      control: Toggle(value: _values.effectiveContentBlock, onChanged: (value) {
        if (value && !ready) _warnNotConfigured(loc.siteSettingsContentBlocker);
        _update(_choices.copyWith(contentBlockEnabled: value));
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
    final chosen = _choices.dnsBlockLevel;
    final title = loc.siteSettingsDnsBlocklistLevel;
    final subtitle = needsDownload
        ? loc.siteSettingsDnsLevelNeedsDownload(
            dnsBlockLevelNames[_effectiveDnsLevel])
        : switch (chosen) {
            FollowApp() => loc.siteSettingsDnsLevelFollowsApp(
                dnsBlockLevelNames[DnsBlockService.instance.level]),
            Own(:final value) => Localized.verbatim(dnsBlockLevelNames[value]),
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
              : (stop) => _update(_choices.copyWith(
                    dnsBlockLevel:
                        stop == _followsAppStop ? const FollowApp() : Own(stop),
                  )),
          // Fetching waits for the drag to settle: every stop the thumb
          // crosses is a level, and downloading each one would pull four
          // lists nobody asked for.
          onChangeEnd: (stop) {
            if (stop != _followsAppStop &&
                !DnsBlockService.instance.downloadedLevels.contains(stop)) {
              unawaited(_downloadLevel(stop));
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
    final loc = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).toast(loc.siteSettingsDnsLevelDownloading);
    final ok = await DnsBlockService.instance.downloadLevel(level);
    if (!mounted) return;
    setState(() => _downloadingLevel = null);
    if (!ok) {
      ScaffoldMessenger.of(context).toast(loc.siteSettingsDnsLevelDownloadFailed);
    }
  }

  Widget _contentBlockerLists(AppLocalizations loc) {
    final available =
        ContentBlockerService.instance.lists.where((l) => l.enabled).toList();
    if (available.isEmpty) return const SizedBox.shrink();
    final off = ArchiveFold.disabledFilterLists(
        _choices.disabledFilterLists.items,
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
    final off = {..._choices.disabledFilterLists.items};
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
    _update(_choices.copyWith(disabledFilterLists: ValueSet(off)));
  }

  Widget _localCdn(AppLocalizations loc) {
    final hasCache = LocalCdnService.instance.hasCache;
    return SettingTile(
      title: loc.siteSettingsLocalCdn,
      hint: loc.siteSettingsLocalCdnHint,
      subtitle: loc.siteSettingsLocalCdnResourceCount(
          LocalCdnService.instance.resourceCount),
      lock: !hasCache
          ? Lock.because(loc.siteSettingsLocalCdnNeedsCache)
          : _values.archived
              ? const ArchiveLock()
              : _umbrella(TrackingProtectionForce.localCdn),
      control: Toggle(value: _values.effectiveLocalCdn && hasCache,
          onChanged: (value) =>
              _update(_choices.copyWith(localCdnEnabled: value))),
    );
  }

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
            : (value) => _update(_choices.copyWith(incognito: value)),
      ),
    );
  }

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
          SettingTile(
            title: loc.siteSettingsClearUrls,
            hint: loc.siteSettingsClearUrlsHint,
            subtitle: loc.siteSettingsClearUrlsSubtitle,
            lock: _umbrella(TrackingProtectionForce.clearUrls),
            control: Toggle(value: _values.effectiveClearUrl,
                onChanged: (value) => _update(_choices.copyWith(clearUrlEnabled: value))),
          ),
          _dnsBlocklist(loc),
          if (_values.effectiveDnsBlock && DnsBlockService.instance.hasBlocklist)
            _dnsBlocklistLevel(loc),
          if (DnsBlockService.instance.hasBlocklist) _dnsStats(),
          _contentBlocker(loc),
          if (_values.effectiveContentBlock &&
              ContentBlockerService.instance.hasRules)
            _contentBlockerLists(loc),
          if (hostIsAndroid) _localCdn(loc),
          SettingTile(
            title: loc.siteSettingsThirdPartyCookies,
            hint: loc.siteSettingsThirdPartyCookiesHint,
            subtitle: loc.siteSettingsThirdPartyCookiesSubtitle,
            lock: _umbrella(TrackingProtectionForce.thirdPartyCookies),
            control: Toggle(
                value: _values.effectiveThirdPartyCookies,
                onChanged: (value) =>
                    _update(_choices.copyWith(thirdPartyCookiesEnabled: value))),
          ),
          SettingTile(
            title: loc.siteSettingsHttpsUpgrade,
            hint: loc.siteSettingsHttpsUpgradeHint,
            lock: _umbrella(TrackingProtectionForce.httpsUpgrade),
            control: ScopedToggle(
              value: _values.effectiveHttpsUpgrade,
              choice: _choices.httpsUpgrade,
              source: FollowSource.app,
              onChoice: (choice) =>
                  _update(_choices.copyWith(httpsUpgrade: choice)),
            ),
          ),
          SettingsSection(loc.privacyGroupFingerprinting),
          SettingTile(
            title: loc.siteSettingsLetterboxTitle,
            hint: loc.siteSettingsWindowSizeHelper,
            lock: _choices.trackingProtectionEnabled
                ? null
                : Lock.because(loc.siteSettingsNeedsTrackingProtection),
            control: Toggle(
                value: _choices.letterboxEnabled && _choices.trackingProtectionEnabled,
                onChanged: (value) => _update(_choices.copyWith(letterboxEnabled: value))),
          ),
          // Only while the umbrella is on: with it off nothing is being
          // randomised, and the note would be describing something that is
          // not happening.
          if (_choices.trackingProtectionEnabled)
            SettingsNote(loc.privacyFingerprintingNote),
          SettingsSection(loc.privacyGroupSecurity),
          SettingTile(
            title: loc.siteSettingsJavascriptEnabled,
            hint: null,
            control: Toggle(value: _choices.javascriptEnabled,
                onChanged: (value) =>
                    _update(_choices.copyWith(javascriptEnabled: value))),
          ),
          if (hostHasLockdownMode)
            SettingTile(
              title: loc.siteSettingsLockdownMode,
              hint: loc.siteSettingsLockdownModeHint,
              control: ScopedToggle(
                value: _values.effectiveLockdownMode,
                choice: _choices.lockdownMode,
                source: FollowSource.trackingProtection,
                onChoice: (choice) =>
                    _update(_choices.copyWith(lockdownMode: choice)),
              ),
            ),
          if (ScreenCaptureGuard.isSupported) ...[
            SettingsSection(loc.privacyGroupScreenCapture),
            SettingTile(
              title: loc.siteSettingsBlockScreenshots,
              hint: loc.siteSettingsBlockScreenshotsHint,
              lock: AppPref.blockScreenshots.value
                  ? Lock.because(loc.siteSettingsBlockScreenshotsAppWide)
                  : null,
              control: Toggle(value: _values.effectiveBlockScreenshots,
                  onChanged: (value) => _update(_choices.copyWith(blockScreenshots: value))),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
