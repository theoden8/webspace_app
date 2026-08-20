import 'package:webspace/platform/host_platform.dart';

import 'package:flutter/material.dart';

import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
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
    required this.contentBlockEnabled,
    required this.localCdnEnabled,
    required this.thirdPartyCookiesEnabled,
    required this.letterboxEnabled,
    required this.incognito,
  });

  final bool trackingProtectionEnabled;
  final bool clearUrlEnabled;
  final bool dnsBlockEnabled;
  final bool contentBlockEnabled;
  final bool localCdnEnabled;
  final bool thirdPartyCookiesEnabled;
  final bool letterboxEnabled;
  final bool incognito;

  SitePrivacyValues copyWith({
    bool? trackingProtectionEnabled,
    bool? clearUrlEnabled,
    bool? dnsBlockEnabled,
    bool? contentBlockEnabled,
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
        contentBlockEnabled: contentBlockEnabled ?? this.contentBlockEnabled,
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
        readyText: dnsBlockLevelNames[DnsBlockService.instance.level],
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
          if (DnsBlockService.instance.hasBlocklist) _dnsStats(),
          _contentBlocker(loc),
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
