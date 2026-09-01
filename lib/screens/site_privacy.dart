import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_tier_engine.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/widgets/hint_button.dart';

/// Everything the privacy screen may change, in one value so the caller can
/// apply a whole edit in a single `setState`.
///
/// Same contract as `SitePermissionValues`: [SiteSettingsScreen] keeps the
/// fields, the dirty-snapshot diff and the save path, and this is only a
/// different way of presenting them. Moving the fields here would take them
/// out of that diff, which is how unsaved edits get dropped (BUG-006).
class SitePrivacyValues {
  const SitePrivacyValues({
    required this.trackingProtectionEnabled,
    required this.clearUrlEnabled,
    required this.dnsBlockEnabled,
    this.dnsBlockLevel,
    required this.contentBlockEnabled,
    this.disabledFilterLists = const <String>{},
    required this.localCdnEnabled,
    required this.thirdPartyCookiesEnabled,
    required this.letterboxEnabled,
    required this.incognito,
  });

  final bool trackingProtectionEnabled;
  final bool clearUrlEnabled;
  final bool dnsBlockEnabled;

  /// Severity level this site blocks at, or null to follow the app-wide one.
  final int? dnsBlockLevel;
  final bool contentBlockEnabled;

  /// Filter list ids this site opts out of.
  final Set<String> disabledFilterLists;
  final bool localCdnEnabled;
  final bool thirdPartyCookiesEnabled;
  final bool letterboxEnabled;
  final bool incognito;

  /// `dnsBlockLevel` is nullable *and* meaningful when null ("follow the app
  /// setting"), so it can't use the `?? this.` idiom — passing null has to
  /// mean "set it to null", not "leave it".
  static const Object _keep = Object();

  SitePrivacyValues copyWith({
    bool? trackingProtectionEnabled,
    bool? clearUrlEnabled,
    bool? dnsBlockEnabled,
    Object? dnsBlockLevel = _keep,
    bool? contentBlockEnabled,
    Set<String>? disabledFilterLists,
    bool? localCdnEnabled,
    bool? thirdPartyCookiesEnabled,
    bool? letterboxEnabled,
    bool? incognito,
  }) =>
      SitePrivacyValues(
        trackingProtectionEnabled:
            trackingProtectionEnabled ?? this.trackingProtectionEnabled,
        clearUrlEnabled: clearUrlEnabled ?? this.clearUrlEnabled,
        dnsBlockEnabled: dnsBlockEnabled ?? this.dnsBlockEnabled,
        dnsBlockLevel: identical(dnsBlockLevel, _keep)
            ? this.dnsBlockLevel
            : dnsBlockLevel as int?,
        contentBlockEnabled: contentBlockEnabled ?? this.contentBlockEnabled,
        disabledFilterLists: disabledFilterLists ?? this.disabledFilterLists,
        localCdnEnabled: localCdnEnabled ?? this.localCdnEnabled,
        thirdPartyCookiesEnabled:
            thirdPartyCookiesEnabled ?? this.thirdPartyCookiesEnabled,
        letterboxEnabled: letterboxEnabled ?? this.letterboxEnabled,
        incognito: incognito ?? this.incognito,
      );

  /// What each subordinate is doing once the umbrella is applied. Mirrors the
  /// `effective*` getters on `WebViewModel`, which is what the webview
  /// actually runs with; the screen must not disagree with them.
  bool get effectiveClearUrl => clearUrlEnabled || trackingProtectionEnabled;
  bool get effectiveDnsBlock => dnsBlockEnabled || trackingProtectionEnabled;
  bool get effectiveContentBlock =>
      contentBlockEnabled || trackingProtectionEnabled;
  bool get effectiveLocalCdn => localCdnEnabled || trackingProtectionEnabled;

  /// The one subordinate the umbrella forces *off*: third-party cookies are
  /// the oldest cross-site tracking channel, so leaving them on under
  /// tracking protection would be the umbrella's largest hole (ETP-024).
  bool get effectiveThirdPartyCookies =>
      thirdPartyCookiesEnabled && !trackingProtectionEnabled;
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

  /// Persistent counterpart of [_warnNotConfigured]: rendered next to a
  /// blocker row whose toggle is effectively on while its data is still
  /// missing, so the gap stays visible after the SnackBar is gone.
  Widget _warnIcon() => const Padding(
        padding: EdgeInsets.only(left: 4),
        child: Icon(Icons.warning_amber_rounded, size: 18, color: Colors.orange),
      );

  /// Subtitle for the DNS blocklist / content blocker rows. The umbrella
  /// forcing them on is not repeated here: the row is already greyed and
  /// unresponsive, and saying so on every row buried the one fact the
  /// subtitle carries, which is whether the data has been downloaded.
  String _blockerSubtitle({required bool ready, required String readyText}) {
    final loc = AppLocalizations.of(context);
    return ready ? readyText : loc.siteSettingsNotConfigured;
  }

  Widget _groupHeader(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  Widget _tile({
    required String title,
    required String hint,
    required bool value,
    required ValueChanged<bool>? onChanged,
    String? subtitle,
    bool warn = false,
    Color? subtitleColor,
  }) =>
      SwitchListTile(
        title: Row(
          children: [
            Flexible(child: Text(title)),
            HintButton(title: title, description: hint),
            if (warn) _warnIcon(),
          ],
        ),
        subtitle: subtitle == null
            ? null
            : Text(subtitle, style: TextStyle(color: subtitleColor)),
        value: value,
        onChanged: onChanged,
      );

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
        title: Row(
          children: [
            Flexible(
              child: Text(
                loc.siteSettingsTrackingProtection,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
            HintButton(
              title: loc.siteSettingsTrackingProtection,
              description: loc.siteSettingsTrackingProtectionHint,
            ),
            if (unconfigured) _warnIcon(),
          ],
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

  Widget _clearUrls(AppLocalizations loc) => _tile(
        title: loc.siteSettingsClearUrls,
        hint: loc.siteSettingsClearUrlsHint,
        subtitle: loc.siteSettingsClearUrlsSubtitle,
        value: _values.effectiveClearUrl,
        onChanged: _values.trackingProtectionEnabled
            ? null
            : (value) => _update(_values.copyWith(clearUrlEnabled: value)),
      );

  Widget _dnsBlocklist(AppLocalizations loc) {
    final missing =
        _values.effectiveDnsBlock && !DnsBlockService.instance.hasBlocklist;
    return _tile(
      title: loc.siteSettingsDnsBlocklist,
      hint: loc.siteSettingsDnsBlocklistHint,
      warn: missing,
      subtitle: _blockerSubtitle(
        ready: DnsBlockService.instance.hasBlocklist,
        readyText: dnsBlockLevelNames[_effectiveDnsLevel],
      ),
      subtitleColor: missing ? Colors.orange : null,
      value: _values.effectiveDnsBlock,
      onChanged: _values.trackingProtectionEnabled
          ? null
          : (value) {
              if (value && !DnsBlockService.instance.hasBlocklist) {
                _warnNotConfigured(loc.siteSettingsDnsBlocklist);
              }
              _update(_values.copyWith(dnsBlockEnabled: value));
            },
    );
  }

  Widget _contentBlocker(AppLocalizations loc) {
    final missing =
        _values.effectiveContentBlock && !ContentBlockerService.instance.hasRules;
    return _tile(
      title: loc.siteSettingsContentBlocker,
      hint: loc.siteSettingsContentBlockerHint,
      warn: missing,
      subtitle: _blockerSubtitle(
        ready: ContentBlockerService.instance.hasRules,
        readyText: loc.siteSettingsContentBlockerRuleCount(
            ContentBlockerService.instance.totalRuleCount),
      ),
      subtitleColor: missing ? Colors.orange : null,
      value: _values.effectiveContentBlock,
      onChanged: _values.trackingProtectionEnabled
          ? null
          : (value) {
              if (value && !ContentBlockerService.instance.hasRules) {
                _warnNotConfigured(loc.siteSettingsContentBlocker);
              }
              _update(_values.copyWith(contentBlockEnabled: value));
            },
    );
  }

  /// Severity level the site's DNS checks actually run at.
  int get _effectiveDnsLevel =>
      DnsBlockService.instance.effectiveLevelFor(_values.dnsBlockLevel);

  bool get _dnsLevelNeedsDownload => dnsLevelNeedsDownload(
        siteLevel: _values.dnsBlockLevel,
        downloadedLevels: DnsBlockService.instance.downloadedLevels,
      );

  Widget _dnsBlocklistLevel(AppLocalizations loc) {
    final needsDownload = _dnsLevelNeedsDownload;
    final chosen = _values.dnsBlockLevel;
    final title = loc.siteSettingsDnsBlocklistLevel;
    final subtitle = needsDownload
        ? loc.siteSettingsDnsLevelNeedsDownload(
            dnsBlockLevelNames[_effectiveDnsLevel])
        : (chosen == null
            ? loc.siteSettingsDnsLevelFollowsApp(
                dnsBlockLevelNames[DnsBlockService.instance.level])
            : dnsBlockLevelNames[chosen]);
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      title: Row(
        children: [
          Flexible(child: Text(title)),
          HintButton(
              title: title, description: loc.siteSettingsDnsBlocklistLevelHint),
          if (needsDownload) _warnIcon(),
        ],
      ),
      subtitle: Text(subtitle,
          style: TextStyle(color: needsDownload ? Colors.orange : null)),
      trailing: _downloadingLevel != null
          ? const SizedBox(
              width: 18, height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_right, size: 18),
      onTap: _downloadingLevel != null ? null : _pickDnsLevel,
    );
  }

  Future<void> _pickDnsLevel() async {
    final loc = AppLocalizations.of(context);
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(loc.siteSettingsDnsBlocklistLevel),
        children: [
          // Sentinel for "follow the app setting": the picker never stores
          // level 0, since the row's own switch is what turns DNS off.
          RadioListTile<int>(
            value: -1,
            groupValue: _values.dnsBlockLevel ?? -1,
            title: Text(loc.siteSettingsDnsLevelFollowApp),
            onChanged: (v) => Navigator.pop(context, v),
          ),
          for (var level = 1; level <= kDnsMaxLevel; level++)
            RadioListTile<int>(
              value: level,
              groupValue: _values.dnsBlockLevel ?? -1,
              title: Text(dnsBlockLevelNames[level]),
              onChanged: (v) => Navigator.pop(context, v),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    final level = picked < 0 ? null : picked;
    _update(_values.copyWith(dnsBlockLevel: level));
    if (level != null &&
        !DnsBlockService.instance.downloadedLevels.contains(level)) {
      await _downloadLevel(level);
    }
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
    final off = _values.disabledFilterLists;
    final onCount = available.where((l) => !off.contains(l.id)).length;
    final title = loc.siteSettingsContentBlockerLists;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 32, right: 16),
      title: Row(
        children: [
          Flexible(child: Text(title)),
          HintButton(
              title: title,
              description: loc.siteSettingsContentBlockerListsHint),
        ],
      ),
      subtitle: Text(loc.siteSettingsContentBlockerListsSubtitle(
          onCount, available.length)),
      trailing: const Icon(Icons.chevron_right, size: 18),
      onTap: () => _pickFilterLists(available),
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
    return _tile(
      title: loc.siteSettingsLocalCdn,
      hint: loc.siteSettingsLocalCdnHint,
      subtitle: hasCache
          ? loc.siteSettingsLocalCdnResourceCount(
              LocalCdnService.instance.resourceCount)
          : loc.siteSettingsLocalCdnNeedsCache,
      value: _values.effectiveLocalCdn && hasCache,
      onChanged: _values.trackingProtectionEnabled
          ? null
          : (hasCache
              ? (value) => _update(_values.copyWith(localCdnEnabled: value))
              : null),
    );
  }

  Widget _thirdPartyCookies(AppLocalizations loc) => _tile(
        title: loc.siteSettingsThirdPartyCookies,
        hint: loc.siteSettingsThirdPartyCookiesHint,
        // The one forced row that keeps its note. Everything else the
        // umbrella touches it turns on, which a greyed-on switch shows by
        // itself; taking something away is the direction that needs saying.
        subtitle: _values.trackingProtectionEnabled
            ? loc.siteSettingsForcedOffByTrackingProtection
            : loc.siteSettingsThirdPartyCookiesSubtitle,
        value: _values.effectiveThirdPartyCookies,
        onChanged: _values.trackingProtectionEnabled
            ? null
            : (value) =>
                _update(_values.copyWith(thirdPartyCookiesEnabled: value)),
      );

  // --- Fingerprinting ------------------------------------------------------

  Widget _letterbox(AppLocalizations loc) => _tile(
        title: loc.siteSettingsLetterboxTitle,
        hint: loc.siteSettingsWindowSizeHelper,
        subtitle: _values.trackingProtectionEnabled
            ? null
            : loc.siteSettingsNeedsTrackingProtection,
        value: _values.letterboxEnabled && _values.trackingProtectionEnabled,
        onChanged: _values.trackingProtectionEnabled
            ? (value) => _update(_values.copyWith(letterboxEnabled: value))
            : null,
      );

  // --- Storage -------------------------------------------------------------

  /// Sits above the umbrella, not under it. Incognito is the bluntest thing
  /// on the screen (nothing survives the session at all), and unlike the
  /// blockers it costs the user their own logins, so it stays their call.
  Widget _incognitoCard(AppLocalizations loc) {
    final scheme = Theme.of(context).colorScheme;
    final on = _values.incognito;
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
        subtitle: Text(loc.siteSettingsIncognitoSubtitle,
            style: const TextStyle(fontSize: 12.5)),
        value: on,
        onChanged: (value) => _update(_values.copyWith(incognito: value)),
      ),
    );
  }

  // --- DNS counters --------------------------------------------------------

  Widget _dnsStats() {
    final loc = AppLocalizations.of(context);
    final stats = DnsBlockService.instance.statsForSite(widget.siteId);
    if (stats.total == 0) return const SizedBox.shrink();
    final totalValue = '${stats.total}';
    final allowedValue = '${stats.allowed}';
    final blockedValue = '${stats.blocked}';
    final blockRateValue = '${stats.blockRate.toStringAsFixed(1)}%';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _statChip(totalValue, loc.siteSettingsDnsStatTotal, Colors.blue),
          const SizedBox(width: 6),
          _statChip(allowedValue, loc.siteSettingsDnsStatAllowed, Colors.green),
          const SizedBox(width: 6),
          _statChip(blockedValue, loc.siteSettingsDnsStatBlocked, Colors.red),
          const SizedBox(width: 6),
          _statChip(blockRateValue, loc.siteSettingsDnsStatBlocked, Colors.orange),
        ],
      ),
    );
  }

  Widget _statChip(String value, String label, Color color) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          decoration: BoxDecoration(
            color: color.withAlpha(20),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withAlpha(50)),
          ),
          child: Column(
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: color)),
              Text(label,
                  style: TextStyle(fontSize: 9, color: color.withAlpha(180))),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.privacyTitle)),
      body: ListView(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
              widget.host,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          _incognitoCard(loc),
          _trackingProtectionCard(loc),
          _groupHeader(loc.privacyGroupTrackers),
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
          _groupHeader(loc.privacyGroupFingerprinting),
          _letterbox(loc),
          // Only while the umbrella is on: with it off nothing is being
          // randomised, and the note would be describing something that is
          // not happening.
          if (_values.trackingProtectionEnabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(
                loc.privacyFingerprintingNote,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
