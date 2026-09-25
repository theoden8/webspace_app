/// Pure-Dart plan for applying a settings backup: everything the import does
/// to live state is decided here, before any of it is touched, so a backup
/// that cannot be applied whole is refused whole. `_importSettings` shows the
/// dialogs, calls [planSettingsImport] and carries the plan out.
///
/// Backups carry no reliable format marker (`version` has been 1 since the
/// first release), so every legacy shape is recognised from the data itself.
/// `test/settings_backup_compat_test.dart` replays what each release really
/// exported through this engine.
library;

import 'dart:convert';

import 'package:webspace/services/dns_level_mask_engine.dart'
    show kDnsLevelOff, kDnsMaxLevel;
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/global_outbound_proxy.dart'
    show kGlobalOutboundProxyKey;
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// A suggested site as the backup lists it.
typedef ImportedSuggestion = ({String name, String url, String domain});

class SettingsImportPlan {
  final List<WebViewModel> sites;

  /// [Webspace.all] first, then the backup's webspaces with `siteIds`
  /// resolved against [sites].
  final List<Webspace> webspaces;

  /// In the current `themeMode * 10 + accent` encoding.
  final int themeStorageIndex;

  /// Every `kExportedAppPrefs` key with a value of the registry's type.
  final Map<String, Object> appPrefs;

  final String selectedWebspaceId;
  final int? currentIndex;

  /// Null when the backup has no such section, which leaves the device's
  /// own list alone.
  final List<UserScriptConfig>? globalUserScripts;
  final List<ImportedSuggestion>? suggestedSites;
  final int? dnsBlockLevel;
  final List<Map<String, dynamic>>? contentBlockerLists;
  final List<String> extraSections;

  /// The backup named a proxy username, so its password (never exported)
  /// has to be re-entered.
  final bool proxyPasswordsNeeded;
  final bool blocklistsNeedDownload;

  const SettingsImportPlan({
    required this.sites,
    required this.webspaces,
    required this.themeStorageIndex,
    required this.appPrefs,
    required this.selectedWebspaceId,
    required this.currentIndex,
    required this.globalUserScripts,
    required this.suggestedSites,
    required this.dnsBlockLevel,
    required this.contentBlockerLists,
    required this.extraSections,
    required this.proxyPasswordsNeeded,
    required this.blocklistsNeedDownload,
  });
}

/// Build the plan for [backup]. Throws when a site cannot be parsed; nothing
/// has been applied at that point, so the caller reports the backup invalid
/// and leaves live state as it was.
SettingsImportPlan planSettingsImport(
  SettingsBackup backup, {
  Function? stateSetterF,
}) {
  final sites = <WebViewModel>[];
  final seenIds = <String>{};
  for (final raw in backup.sites) {
    var json = raw;
    final id = sanitizedSiteId(json['siteId']);
    // Two sites sharing a siteId would share one container: one cookie jar,
    // one storage partition. The first keeps the id, later ones get fresh.
    if (id != null && !seenIds.add(id)) {
      json = Map<String, dynamic>.from(json)..remove('siteId');
    }
    sites.add(WebViewModel.fromJson(json, stateSetterF));
  }
  sanitizeImportedSites(sites);

  final webspaces = SettingsBackupService.restoreWebspaces(backup);
  _dedupeWebspaceIds(webspaces);
  promoteLegacySiteIndices(webspaces, sites);
  final known = {for (final s in sites) s.siteId};
  for (final ws in webspaces) {
    if (ws.isAll) continue;
    final seen = <String>{};
    ws.siteIds = [
      for (final id in ws.siteIds)
        if (known.contains(id) && seen.add(id)) id,
    ];
  }
  // LIR-017: a restored site routes only to a site the backup restores.
  OutboundPreferenceGc.pruneAll<WebViewModel>(
    sites,
    prefsOf: (s) => s.outboundPreferences,
    setPrefs: (s, prefs) => s.outboundPreferences = prefs,
    isCandidate: (_, id) => known.contains(id),
  );

  final selected = backup.selectedWebspaceId;
  final current = backup.currentIndex;

  return SettingsImportPlan(
    sites: sites,
    webspaces: webspaces,
    themeStorageIndex: normalizeBackupThemeIndex(backup.themeMode, backup.sites),
    appPrefs: resolveExportedAppPrefs(backup.globalPrefs),
    selectedWebspaceId:
        selected != null && webspaces.any((ws) => ws.id == selected)
            ? selected
            : kAllWebspaceId,
    currentIndex:
        current != null && current >= 0 && current < sites.length
            ? current
            : null,
    globalUserScripts: backup.globalUserScripts == null
        ? null
        : [
            for (final e in backup.globalUserScripts!) ?_scriptOrNull(e),
          ],
    suggestedSites: backup.suggestedSites == null
        ? null
        : [
            for (final e in backup.suggestedSites!)
              if ((e['name'], e['url'], e['domain'])
                  case (final String name, final String url, final String domain))
                (name: name, url: url, domain: domain),
          ],
    dnsBlockLevel: switch (backup.dnsBlockLevel) {
      final int level when level >= kDnsLevelOff && level <= kDnsMaxLevel =>
        level,
      _ => null,
    },
    contentBlockerLists: backup.contentBlockerLists == null
        ? null
        : [
            for (final e in backup.contentBlockerLists!)
              {
                'id': e['id'] is String ? e['id'] : null,
                'name': e['name'] is String ? e['name'] : null,
                'url': e['url'] is String ? e['url'] : null,
                'enabled': e['enabled'] == true,
              },
          ],
    extraSections: backup.extraSections ?? const [],
    proxyPasswordsNeeded: _backupNamesProxyUsername(backup),
    blocklistsNeedDownload: (backup.dnsBlockLevel is int &&
            backup.dnsBlockLevel! > kDnsLevelOff) ||
        (backup.contentBlockerLists?.any((e) => e['enabled'] == true) ??
            false),
  );
}

/// Strip what a backup file must not be able to hand a restored site
/// (BACKUP-011). A backup is a plain JSON file the user was given, so
/// everything in it is attacker-authorable:
///   * a proxy password never rides an export (PWD-005) and so can only have
///     been hand-written in; restoring it would point the site's traffic at
///     someone else's authenticated proxy;
///   * a user script injects at document start with full page privileges, on
///     whatever site the same file chose. Nothing restored runs before the
///     user has opened it and said yes;
///   * a permission grant is consent the user gave on the exporting device.
void sanitizeImportedSites(List<WebViewModel> sites) {
  for (final site in sites) {
    site.proxySettings.password = null;
    // Global scripts inject on per-site opt-in regardless of their own
    // `enabled` flag (`combineUserScripts` forces that true), so the opt-in
    // set is what has to be dropped.
    site.enabledGlobalScriptIds.clear();
    for (final script in site.userScripts) {
      script.enabled = false;
    }
    // A grant that hands the page a real device or capability is consent the
    // user gave on the exporting device. Reset each to the state that asks
    // again (or, where the capability has no prompt, to off); simulated and
    // blocked states grant nothing and stay.
    if (site.cameraMode == CameraAccessMode.real) {
      site.cameraMode = CameraAccessMode.ask;
    }
    if (site.microphoneMode == MicrophoneAccessMode.real) {
      site.microphoneMode = MicrophoneAccessMode.ask;
    }
    if (site.locationMode == LocationMode.live) {
      site.locationMode = LocationMode.off;
    }
    if (site.protectedContentAllowed == true) {
      site.protectedContentAllowed = null;
    }
    site.notificationsEnabled = false;
    site.backgroundAudioEnabled = false;
  }
}

/// Webspaces written before membership was keyed by siteId (v0.2.3 and
/// earlier) carry positional `siteIndices`. Resolve them against [sites] in
/// their saved order. Idempotent. Returns whether anything changed.
bool promoteLegacySiteIndices(List<Webspace> webspaces, List<WebViewModel> sites) {
  var migrated = false;
  for (final ws in webspaces) {
    if (ws.isAll) continue;
    if (ws.siteIds.isNotEmpty || ws.siteIndices.isEmpty) continue;
    ws.siteIds = [
      for (final idx in ws.siteIndices)
        if (idx >= 0 && idx < sites.length) sites[idx].siteId,
    ];
    migrated = true;
  }
  return migrated;
}

/// v0.0.4 and v0.0.5 exported `ThemeMode.index` (0 system, 1 light, 2 dark);
/// from v0.1.0 the value is `themeMode * 10 + accent`. The two overlap on
/// 0..2, so the old form is told apart by shape: v0.1.0 also began writing
/// `language` on every site. A negative index would make
/// `AppThemeSettings.fromStorageIndex` read `ThemeMode.values[-1]`.
int normalizeBackupThemeIndex(int raw, List<Map<String, dynamic>> sites) {
  if (raw < 0) return 0;
  final legacy = raw <= 2 &&
      sites.isNotEmpty &&
      !sites.any((s) => s.containsKey('language'));
  return legacy ? raw * 10 : raw;
}

/// `host:port` of the app-wide proxy [backup] would install, or null when it
/// sets none. Shown in the import confirmation.
String? backupGlobalProxyAddress(SettingsBackup backup) {
  final proxy = _decodeProxyPref(backup.globalPrefs[kGlobalOutboundProxyKey]);
  if (proxy == null) return null;
  final type = proxy['type'];
  final address = proxy['address'];
  if (type is! int || type == ProxyType.DEFAULT.index) return null;
  if (address is! String || address.isEmpty) return null;
  return address;
}

/// How many user scripts [backup] would install, global plus per-site.
int backupUserScriptCount(SettingsBackup backup) {
  var count = backup.globalUserScripts?.length ?? 0;
  for (final site in backup.sites) {
    final scripts = site['userScripts'];
    if (scripts is List) count += scripts.length;
  }
  return count;
}

Map<String, dynamic>? _decodeProxyPref(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : null;
  } catch (_) {
    return null;
  }
}

bool _backupNamesProxyUsername(SettingsBackup backup) {
  bool named(Object? proxy) =>
      proxy is Map &&
      proxy['username'] is String &&
      (proxy['username'] as String).isNotEmpty;
  return backup.sites.any((s) => named(s['proxySettings'])) ||
      named(_decodeProxyPref(backup.globalPrefs[kGlobalOutboundProxyKey]));
}

UserScriptConfig? _scriptOrNull(Map<String, dynamic> json) {
  try {
    return UserScriptConfig.fromJson(json)..enabled = false;
  } catch (_) {
    return null;
  }
}

/// A repeated id would make selection and edits land on whichever copy is
/// found first; later copies get a fresh id instead.
void _dedupeWebspaceIds(List<Webspace> webspaces) {
  final seen = <String>{};
  for (final ws in webspaces) {
    if (seen.add(ws.id)) continue;
    ws.id = Webspace(name: ws.name).id;
    seen.add(ws.id);
  }
}
