import 'dart:convert' show base64Decode, base64Encode;
import 'dart:typed_data';

import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/tab_bar_corner.dart';
import 'package:webspace/services/user_agent_preset.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/settings/site_ids.dart';

/// A site's JSON: the form it is saved in and the one a backup carries.
extension WebViewModelJson on WebViewModel {
  /// [WebViewModel.toJson].
  Map<String, dynamic> toJsonMap() {
    // currentUrl/pageTitle are dropped when either incognito (full ephemeral
    // session — issue #298) or alwaysOpenHome (URL-only ephemeral, cookies
    // persist) is set. Cookies are dropped only by incognito; alwaysOpenHome
    // banking-style sites keep their login state.
    // Both keep the tab list (TAB-009): the site lands on a tab at home
    // without closing the others (TAB-014), and what incognito wipes on a
    // restart is its container and every tab's back stack (INC-002, INC-005).
    // `currentUrl` stays dropped so a build that predates tabs still opens the
    // site at home.
    final dropUrl = incognito || alwaysOpenHome;
    return {
        'siteId': siteId,
        'initUrl': initUrl,
        if (!dropUrl) 'currentUrl': currentUrl,
        if (!tabsAreDefault)
          'tabs': [
            for (final t in tabs)
              {...t.toJson(), if (t.id == activeTabId) 'active': true},
          ],
        'name': name,
        if (!dropUrl) 'pageTitle': pageTitle,
        'cookies': incognito
            ? const <Map<String, dynamic>>[]
            : cookies.map((cookie) => cookie.toJson()).toList(),
        'proxySettings': proxySettings.toJson(),
        'javascriptEnabled': javascriptEnabled,
        'userAgent': userAgent,
        if (uaPreset != null) 'uaPreset': uaPreset!.name,
        'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
        'httpsUpgradeEnabled': httpsUpgradeEnabled,
        'incognito': incognito,
        'alwaysOpenHome': alwaysOpenHome,
        'kioskMode': kioskMode,
        if (!tabsEnabled) 'tabsEnabled': false,
        if (containerColor != null) 'containerColor': containerColor,
        'language': language,
        if (zoomPercent != kDefaultZoomPercent) 'zoomPercent': zoomPercent,
        'clearUrlEnabled': clearUrlEnabled,
        'dnsBlockEnabled': dnsBlockEnabled,
        'dnsBlockLevel': dnsBlockLevel,
        'disabledFilterLists': disabledFilterLists.toList()..sort(),
        'contentBlockEnabled': contentBlockEnabled,
        'trackingProtectionEnabled': trackingProtectionEnabled,
        'localCdnEnabled': localCdnEnabled,
        if (externalLinkMode != ExternalLinkMode.inApp)
          'externalLinkMode': externalLinkMode.name,
        'fullscreenMode': fullscreenMode,
        if (blockScreenshots) 'blockScreenshots': true,
        if (tabBarButtonCorner != null)
          'tabBarButtonCorner': tabBarButtonCorner!.name,
        'htmlCachingEnabled': htmlCachingEnabled,
        'notificationsEnabled': notificationsEnabled,
        if (backgroundAudioEnabled) 'backgroundAudioEnabled': true,
        if (protectedContentAllowed != null)
          'protectedContentAllowed': protectedContentAllowed,
        // Virtual-source bytes ride the model like `customIconPng` (backups
        // keep them; archive-tier sites live only inside the encrypted slice).
        ...captures.toJson(),
        'userScripts': userScripts.map((s) => s.toJson()).toList(),
        if (enabledGlobalScriptIds.isNotEmpty)
          'enabledGlobalScriptIds': enabledGlobalScriptIds.toList(),
        if (blockedCookies.isNotEmpty)
          'blockedCookies': blockedCookies.map((b) => b.toJson()).toList(),
        'locationMode': locationMode.name,
        if (spoofLatitude != null) 'spoofLatitude': spoofLatitude,
        if (spoofLongitude != null) 'spoofLongitude': spoofLongitude,
        'spoofAccuracy': spoofAccuracy,
        if (spoofTimezone != null) 'spoofTimezone': spoofTimezone,
        if (spoofTimezoneFromLocation) 'spoofTimezoneFromLocation': true,
        if (liveLocationGranularity != LocationGranularity.gps)
          'liveLocationGranularity': liveLocationGranularity.name,
        'webRtcPolicy': webRtcPolicy.name,
        if (letterboxEnabled) 'letterboxEnabled': true,
        if (spoofWindowWidth != null) 'spoofWindowWidth': spoofWindowWidth,
        if (spoofWindowHeight != null) 'spoofWindowHeight': spoofWindowHeight,
        if (fingerprintResetNonce != null)
          'fingerprintResetNonce': fingerprintResetNonce,
        if (customIconPng != null)
          'customIconPng': base64Encode(customIconPng!),
        if (domainClaims != null && domainClaims!.isNotEmpty)
          'domainClaims': domainClaims!.map((c) => c.toJson()).toList(),
        if (routeOutboundLinks) 'routeOutboundLinks': true,
        if (outboundPreferences.isNotEmpty)
          'outboundPreferences':
              outboundPreferences.map((p) => p.toJson()).toList(),
        if (searchAddress != null) 'searchAddress': searchAddress,
        if (searchesWeb) 'searchesWeb': true,
        // Learned from the site's pages, so incognito keeps it in memory.
        if (!incognito && discoveredSearchAddress != null)
          'discoveredSearchAddress': discoveredSearchAddress,
        if (!incognito && discoveredSearchesWeb) 'discoveredSearchesWeb': true,
        if (searchSites.isNotEmpty) 'searchSites': searchSites,
        if (searchDefault != null) 'searchDefault': searchDefault,
      };
  }
}

/// [WebViewModel.fromJson].
WebViewModel webViewModelFromJson(
  Map<String, dynamic> json, {
  required Function? stateSetterF,
  bool isArchiveTier = false,
}) {
  T? field<T>(String key) {
    final value = json[key];
    return value is T ? value : null;
  }

  num? finite(String key) {
    final value = json[key];
    return value is num && value.isFinite ? value : null;
  }

  final isIncognito = field<bool>('incognito') ?? false;
  final isAlwaysOpenHome = field<bool>('alwaysOpenHome') ?? false;
  // Either flag drops persisted currentUrl/pageTitle on rehydrate; only
  // incognito additionally clears cookies. Defends against legacy JSON
  // written by older builds that didn't strip on toJson.
  final dropUrl = isIncognito || isAlwaysOpenHome;
  final currentUrl = field<String>('currentUrl');
  final rawTabs = field<List<dynamic>>('tabs');
  final userAgent = field<String>('userAgent') ?? '';
  final proxy = json['proxySettings'];
  final model = WebViewModel(
    // Validate against path-safe format: a crafted backup could otherwise
    // set siteId to `../…` and escape the cache/import/storage keyspace.
    // null (missing or unsafe) auto-generates a fresh id.
    siteId: sanitizedSiteId(json['siteId']),
    initUrl: migrateLegacyFileImportUrl(json['initUrl'] as String),
    currentUrl: dropUrl || currentUrl == null
        ? null
        : migrateLegacyFileImportUrl(currentUrl),
    // JSON without `tabs` is a site written before tabs existed, or one that
    // never opened a second tab: the constructor synthesises the primary tab
    // from `currentUrl`. A list that is present is authoritative, and
    // `currentUrl`/`pageTitle` beside it are only the copy older builds read.
    // Entries that cannot name a tab are dropped rather than sinking the site.
    tabs: rawTabs
        ?.map(SiteTab.fromJson)
        .whereType<SiteTab>()
        .map((t) => t..url = migrateLegacyFileImportUrl(t.url))
        .toList(),
    activeTabId: SiteTab.activeIdIn(rawTabs),
    name: field<String>('name'),
    cookies: isIncognito
        ? const <Cookie>[]
        : _jsonEntries(json['cookies'], parse: tryCookieFromJson),
    proxySettings: proxy is Map
        ? UserProxySettings.fromJson(Map<String, dynamic>.from(proxy))
        : null,
    javascriptEnabled: field<bool>('javascriptEnabled') ?? true,
    // Migration: a stored string that is a stock webview-default shape is
    // a frozen snapshot of the device default (old settings-screen builds
    // pre-filled the field with the default and persisted it on save).
    // Drop the override so the site tracks the live default again.
    userAgent: isStockWebViewDefaultUserAgent(userAgent) ? '' : userAgent,
    // Migration: legacy data carries only the rendered string. A string
    // matching a generated shape (including shapes old buggy builds
    // emitted) gets its preset back here, so stale persisted UAs heal on
    // load instead of rotting until a site breaks on them.
    uaPreset: userAgentPresetFromName(field<String>('uaPreset')) ??
        recognizeGeneratedUserAgent(userAgent),
    thirdPartyCookiesEnabled: field<bool>('thirdPartyCookiesEnabled') ?? false,
    httpsUpgradeEnabled: field<bool>('httpsUpgradeEnabled'),
    incognito: isIncognito,
    alwaysOpenHome: isAlwaysOpenHome,
    kioskMode: field<bool>('kioskMode') ?? false,
    tabsEnabled: field<bool>('tabsEnabled') ?? true,
    containerColor: switch (field<int>('containerColor')) {
      final int i when i >= 0 => i,
      _ => null,
    },
    language: sanitizedLanguageTag(json['language']),
    zoomPercent: clampZoomPercent(
        finite('zoomPercent')?.toInt() ?? kDefaultZoomPercent),
    clearUrlEnabled: field<bool>('clearUrlEnabled') ?? true,
    dnsBlockEnabled: field<bool>('dnsBlockEnabled') ?? true,
    dnsBlockLevel: _readDnsBlockLevel(json['dnsBlockLevel']),
    disabledFilterLists: {
      for (final id in field<List>('disabledFilterLists') ?? const [])
        if (id is String) id
    },
    contentBlockEnabled: field<bool>('contentBlockEnabled') ?? true,
    trackingProtectionEnabled:
        field<bool>('trackingProtectionEnabled') ?? true,
    localCdnEnabled: field<bool>('localCdnEnabled') ?? true,
    // `externalLinksInBrowser` is the bool this field replaced.
    externalLinkMode: externalLinkModeFromJson(
        json['externalLinkMode'], legacyInBrowser: json['externalLinksInBrowser']),
    fullscreenMode: field<bool>('fullscreenMode') ?? false,
    blockScreenshots: field<bool>('blockScreenshots') ?? false,
    // `tabBarButtonOnRight` is the short-lived bool predecessor of the
    // four-corner field; map it so early builds rehydrate cleanly.
    tabBarButtonCorner:
        tabBarCornerFromName(field<String>('tabBarButtonCorner')) ??
            switch (field<bool>('tabBarButtonOnRight')) {
              null => null,
              true => TabBarCorner.bottomRight,
              false => TabBarCorner.bottomLeft,
            },
    htmlCachingEnabled: field<bool>('htmlCachingEnabled') ?? false,
    notificationsEnabled: field<bool>('notificationsEnabled') ??
        field<bool>('backgroundPoll') ??
        false,
    backgroundAudioEnabled: field<bool>('backgroundAudioEnabled') ?? false,
    protectedContentAllowed: field<bool>('protectedContentAllowed'),
    captures: CaptureGrants.fromJson(json),
    userScripts:
        _jsonEntries(json['userScripts'], parse: UserScriptConfig.fromJson),
    enabledGlobalScriptIds: {
      for (final id in field<List>('enabledGlobalScriptIds') ?? const [])
        if (id is String) id
    },
    blockedCookies:
        _jsonEntries(json['blockedCookies'], parse: BlockedCookie.tryFromJson).toSet(),
    locationMode: LocationMode.values.firstWhere(
      (m) => m.name == json['locationMode'],
      orElse: () => LocationMode.off,
    ),
    spoofLatitude: finite('spoofLatitude')?.toDouble(),
    spoofLongitude: finite('spoofLongitude')?.toDouble(),
    spoofAccuracy:
        finite('spoofAccuracy')?.toDouble() ?? kDefaultSpoofAccuracy,
    spoofTimezone: field<String>('spoofTimezone'),
    spoofTimezoneFromLocation:
        field<bool>('spoofTimezoneFromLocation') ?? false,
    liveLocationGranularity: _decodeLiveLocationGranularity(
        json['liveLocationGranularity']),
    webRtcPolicy: WebRtcPolicy.values.firstWhere(
      (p) => p.name == json['webRtcPolicy'],
      orElse: () => WebRtcPolicy.defaultPolicy,
    ),
    letterboxEnabled: field<bool>('letterboxEnabled') ?? false,
    spoofWindowWidth: finite('spoofWindowWidth')?.toInt(),
    spoofWindowHeight: finite('spoofWindowHeight')?.toInt(),
    fingerprintResetNonce: field<String>('fingerprintResetNonce'),
    customIconPng: _decodeCustomIconPng(json['customIconPng']),
    // Absent stays null: no claims configured, as opposed to an emptied list.
    domainClaims: json['domainClaims'] is List
        ? [
            for (final claim
                in _jsonEntries(json['domainClaims'], parse: DomainClaim.tryFromJson))
              if (claim.value.isNotEmpty) claim,
          ]
        : null,
    routeOutboundLinks: field<bool>('routeOutboundLinks') ?? false,
    outboundPreferences: OutboundPreference.dedupedByClaim(
      (field<List<dynamic>>('outboundPreferences') ?? const [])
          .map(OutboundPreference.fromJson)
          .whereType<OutboundPreference>(),
    ),
    searchAddress: field<String>('searchAddress'),
    searchesWeb: field<bool>('searchesWeb') ?? false,
    discoveredSearchAddress: field<String>('discoveredSearchAddress'),
    discoveredSearchesWeb: field<bool>('discoveredSearchesWeb') ?? false,
    searchSites: [
      for (final id in field<List<dynamic>>('searchSites') ?? const [])
        if (sanitizedSiteId(id) case final String safe) safe,
    ],
    searchDefault: sanitizedSiteId(json['searchDefault']),
    stateSetterF: stateSetterF,
    isArchiveTier: isArchiveTier,
  )..pageTitle ??= dropUrl ? null : field<String>('pageTitle');
  // Loading a site is a fresh entry to it, so an always-home site lands at
  // home here (AOH-002, TAB-014), before anything can build its webview.
  if (isAlwaysOpenHome && !isIncognito) {
    model.landAtHome();
  }
  return model;
}

/// A stored level outside 0..5 (hand-edited backup, a future build's
/// wider range) means "follow the app-wide level" rather than an
/// out-of-range block posture.
int? _readDnsBlockLevel(dynamic raw) {
  if (raw is! int) return null;
  if (raw < kDnsLevelOff || raw > kDnsMaxLevel) return null;
  return raw;
}

/// The entries of a JSON list that [parse] accepts. A malformed entry (a
/// cookie, a script, a claim) is dropped rather than failing its site.
List<T> _jsonEntries<T extends Object>(
  Object? raw, {
  required T? Function(Map<String, dynamic>) parse,
}) =>
    raw is List
        ? [
            for (final entry in raw)
              if (entry is Map<String, dynamic>) ?parse(entry),
          ]
        : <T>[];

Uint8List? _decodeCustomIconPng(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  try {
    return base64Decode(raw);
  } on FormatException {
    return null;
  }
}

/// Legacy enum values written before the three-tier rename are migrated:
/// `"fine"` (pre-#326 default = raw GPS) → [LocationGranularity.gps],
/// `"coarse"` (pre-#326 cell-tower-only) → [LocationGranularity.gsm].
/// Anything unrecognised or absent falls through to [LocationGranularity.gps].
LocationGranularity _decodeLiveLocationGranularity(Object? raw) {
  if (raw is String) {
    if (raw == 'fine') return LocationGranularity.gps;
    if (raw == 'coarse') return LocationGranularity.gsm;
    for (final v in LocationGranularity.values) {
      if (v.name == raw) return v;
    }
  }
  return LocationGranularity.gps;
}

/// The per-site `language` is a constrained dropdown in the UI, but an
/// imported backup or scanned QR can carry an arbitrary string. It is
/// interpolated raw into the `Accept-Language` request header, so a value
/// with CRLF could smuggle extra headers into the site's requests. Accept
/// only a BCP-47-shaped tag (`en`, `zh-CN`, …); anything else returns null
/// (system default), matching the siteId hardening.
final RegExp _kLanguageTagPattern =
    RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$');

String? sanitizedLanguageTag(Object? raw) {
  if (raw is! String || raw.isEmpty) return null;
  return _kLanguageTagPattern.hasMatch(raw) ? raw : null;
}
