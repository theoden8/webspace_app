import 'dart:convert' show base64Decode, base64Encode;
import 'dart:typed_data';

import 'package:webspace/settings/filter_list_id.dart';
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
import 'package:webspace/settings/site_field.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/settings/web_view_theme.dart';
import 'package:webspace/utils/url_utils.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/page_zoom_shim.dart';
import 'package:webspace/settings/site_ids.dart';

/// A site's JSON: the form it is saved in and the one a backup carries.
extension WebViewModelJson on WebViewModel {
  /// [WebViewModel.toJson].
  // currentUrl/pageTitle are dropped when either incognito (full ephemeral
  // session — issue #298) or alwaysOpenHome (URL-only ephemeral, cookies
  // persist) is set. Cookies are dropped only by incognito; alwaysOpenHome
  // banking-style sites keep their login state.
  // Both keep the tab list (TAB-009): the site lands on a tab at home
  // without closing the others (TAB-014), and what incognito wipes on a
  // restart is its container and every tab's back stack (INC-002, INC-005).
  // `currentUrl` stays dropped so a build that predates tabs still opens the
  // site at home.
  Map<String, dynamic> toJsonMap() =>
      _jsonMap(dropUrl: incognito || alwaysOpenHome);

  /// [WebViewModel.toArchiveJson]: [toJsonMap] with the address and title
  /// kept, so opening the archive brings the site back where it was
  /// (ARCH-012). The archive is encrypted and opening it is not a fresh
  /// entry, so neither reason to drop them applies.
  Map<String, dynamic> toArchiveJsonMap() => _jsonMap(dropUrl: false);

  Map<String, dynamic> _jsonMap({required bool dropUrl}) => {
        for (final field in SiteField.values)
          ..._written(field, dropUrl: dropUrl),
      };

  /// What a save writes for [field]: nothing where it leaves a default out.
  Map<String, Object?> _written(SiteField field, {required bool dropUrl}) {
    final key = field.key;
    return switch (field) {
      SiteField.siteId => {key: siteId},
      SiteField.initUrl => {key: initUrl},
      SiteField.currentUrl => {if (!dropUrl) key: currentUrl},
      SiteField.tabs => {
          if (!tabsAreDefault)
            key: [
              for (final t in tabs)
                {...t.toJson(), if (t.id == activeTabId) 'active': true},
            ],
        },
      SiteField.name => {key: name},
      SiteField.pageTitle => {if (!dropUrl) key: pageTitle},
      SiteField.cookies => {
          key: incognito
              ? const <Map<String, dynamic>>[]
              : cookies.map((cookie) => cookie.toJson()).toList(),
        },
      SiteField.proxySettings => {key: proxySettings.toJson()},
      SiteField.javascriptEnabled => {key: javascriptEnabled},
      SiteField.userAgent => {key: userAgent},
      SiteField.uaPreset => {if (uaPreset != null) key: uaPreset!.name},
      SiteField.thirdPartyCookiesEnabled => {key: thirdPartyCookiesEnabled},
      SiteField.httpsUpgradeEnabled => {key: httpsUpgradeEnabled},
      SiteField.incognito => {key: incognito},
      SiteField.alwaysOpenHome => {key: alwaysOpenHome},
      SiteField.kioskMode => {key: kioskMode},
      SiteField.tabsEnabled => {key: tabsEnabled},
      SiteField.containerColor => {
          if (containerColor != null) key: containerColor,
        },
      SiteField.language => {key: language},
      SiteField.zoomPercent => {
          if (zoomPercent != kDefaultZoomPercent) key: zoomPercent,
        },
      SiteField.theme => {if (theme != null) key: theme!.name},
      SiteField.clearUrlEnabled => {key: clearUrlEnabled},
      SiteField.dnsBlockEnabled => {key: dnsBlockEnabled},
      SiteField.dnsBlockLevel => {key: dnsBlockLevel},
      SiteField.disabledFilterLists => {
          key: disabledFilterLists.toList()..sort(),
        },
      SiteField.contentBlockEnabled => {key: contentBlockEnabled},
      SiteField.trackingProtectionEnabled => {key: trackingProtectionEnabled},
      SiteField.localCdnEnabled => {key: localCdnEnabled},
      SiteField.externalLinkMode => {key: externalLinkMode?.name},
      SiteField.fullscreenMode => {key: fullscreenMode},
      SiteField.blockScreenshots => {if (blockScreenshots) key: true},
      SiteField.tabBarButtonCorner => {
          if (tabBarButtonCorner != null) key: tabBarButtonCorner!.name,
        },
      SiteField.htmlCachingEnabled => {key: htmlCachingEnabled},
      SiteField.notificationsEnabled => {key: notificationsEnabled},
      SiteField.backgroundAudioEnabled => {
          if (backgroundAudioEnabled) key: true,
        },
      SiteField.protectedContentAllowed => {
          if (protectedContentAllowed != null) key: protectedContentAllowed,
        },
      // Virtual-source bytes ride the model like `customIconPng` (backups
      // keep them; archive-tier sites live only inside the encrypted slice).
      SiteField.captures => captures.toJson(),
      SiteField.userScripts => {
          key: userScripts.map((s) => s.toJson()).toList(),
        },
      SiteField.enabledGlobalScriptIds => {
          if (enabledGlobalScriptIds.isNotEmpty)
            key: enabledGlobalScriptIds.toList(),
        },
      SiteField.blockedCookies => {
          if (blockedCookies.isNotEmpty)
            key: blockedCookies.map((b) => b.toJson()).toList(),
        },
      SiteField.locationMode => {key: locationMode.name},
      SiteField.spoofLatitude => {if (spoofLatitude != null) key: spoofLatitude},
      SiteField.spoofLongitude => {
          if (spoofLongitude != null) key: spoofLongitude,
        },
      SiteField.spoofAccuracy => {key: spoofAccuracy},
      SiteField.spoofTimezone => {if (spoofTimezone != null) key: spoofTimezone},
      SiteField.spoofTimezoneFromLocation => {
          if (spoofTimezoneFromLocation) key: true,
        },
      SiteField.liveLocationGranularity => {
          if (liveLocationGranularity != LocationGranularity.gps)
            key: liveLocationGranularity.name,
        },
      SiteField.webRtcPolicy => {key: webRtcPolicy.name},
      SiteField.letterboxEnabled => {if (letterboxEnabled) key: true},
      SiteField.spoofWindowWidth => {
          if (spoofWindowWidth != null) key: spoofWindowWidth,
        },
      SiteField.spoofWindowHeight => {
          if (spoofWindowHeight != null) key: spoofWindowHeight,
        },
      SiteField.fingerprintResetNonce => {
          if (fingerprintResetNonce != null) key: fingerprintResetNonce,
        },
      SiteField.customIconPng => {
          if (customIconPng != null) key: base64Encode(customIconPng!),
        },
      SiteField.domainClaims => {
          if (domainClaims != null && domainClaims!.isNotEmpty)
            key: domainClaims!.map((c) => c.toJson()).toList(),
        },
      SiteField.routeOutboundLinks => {key: routeOutboundLinks},
      SiteField.outboundPreferences => {
          if (outboundPreferences.isNotEmpty)
            key: outboundPreferences.map((p) => p.toJson()).toList(),
        },
      SiteField.searchAddress => {if (searchAddress != null) key: searchAddress},
      SiteField.searchesWeb => {if (searchesWeb) key: true},
      // Learned from the site's pages, so incognito keeps it in memory.
      SiteField.discoveredSearchAddress => {
          if (!incognito && discoveredSearchAddress != null)
            key: discoveredSearchAddress,
        },
      SiteField.discoveredSearchesWeb => {
          if (!incognito && discoveredSearchesWeb) key: true,
        },
      SiteField.searchSites => {if (searchSites.isNotEmpty) key: searchSites},
      SiteField.searchDefault => {if (searchDefault != null) key: searchDefault},
    };
  }
}

/// [WebViewModel.fromJson].
WebViewModel webViewModelFromJson(
  Map<String, dynamic> json, {
  required Function? stateSetterF,
  bool isArchiveTier = false,
}) {
  final read = _SiteJson(json, isArchiveTier: isArchiveTier);
  final rawTabs = read.value<List<dynamic>>(SiteField.tabs);
  final currentUrl = read.value<String>(SiteField.currentUrl);
  final model = WebViewModel(
    // Validate against path-safe format: a crafted backup could otherwise
    // set siteId to `../…` and escape the cache/import/storage keyspace.
    // null (missing or unsafe) auto-generates a fresh id.
    siteId: SiteId.parse(json[SiteField.siteId.key]),
    initUrl: migrateLegacyFileImportUrl(switch (json[SiteField.initUrl.key]) {
      final String url => url,
      _ => throw const FormatException('a site has no initUrl'),
    }),
    currentUrl: read.dropUrl || currentUrl == null
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
    stateSetterF: stateSetterF,
    isArchiveTier: isArchiveTier,
  );
  for (final field in SiteField.values) {
    read.into(model, field: field);
  }
  // Loading a site is a fresh entry to it, so an always-home site lands at
  // home here (AOH-002, TAB-014), before anything can build its webview.
  // Opening an archive is not one: it restores what it sealed (ARCH-012).
  if (read.alwaysOpenHome && !read.incognito && !isArchiveTier) {
    model.landAtHome();
  }
  return model;
}

/// A site's JSON as a read takes it: a value of the wrong type reads as
/// absent, and the flags other fields depend on are read first.
class _SiteJson {
  _SiteJson(this.json, {required bool isArchiveTier}) {
    incognito = value<bool>(SiteField.incognito) ?? false;
    alwaysOpenHome = value<bool>(SiteField.alwaysOpenHome) ?? false;
    // Either flag drops persisted currentUrl/pageTitle on rehydrate; only
    // incognito additionally clears cookies. Defends against legacy JSON
    // written by older builds that didn't strip on toJson. An archive keeps
    // them (ARCH-012).
    dropUrl = !isArchiveTier && (incognito || alwaysOpenHome);
  }

  final Map<String, dynamic> json;
  late final bool incognito;
  late final bool alwaysOpenHome;
  late final bool dropUrl;

  T? value<T>(SiteField field) => switch (json[field.key]) {
        final T v => v,
        _ => null,
      };

  /// [field]'s one older name, as a read still takes it.
  Object? legacy(SiteField field) => json[field.legacyKeys.single];

  num? finite(SiteField field) => switch (json[field.key]) {
        final num v when v.isFinite => v,
        _ => null,
      };

  /// Sets [field] on [model] as [json] has it.
  void into(WebViewModel model, {required SiteField field}) {
    final raw = json[field.key];
    switch (field) {
      // Read by the constructor: the tab list is built from them.
      case SiteField.siteId ||
            SiteField.initUrl ||
            SiteField.currentUrl ||
            SiteField.tabs:
        break;
      case SiteField.name:
        if (value<String>(field) case final name?) model.name = name;
      case SiteField.pageTitle:
        model.pageTitle ??= dropUrl ? null : value<String>(field);
      case SiteField.cookies:
        model.cookies = incognito
            ? const <Cookie>[]
            : _jsonEntries(raw, parse: tryCookieFromJson);
      case SiteField.proxySettings:
        if (raw is Map) {
          model.proxySettings =
              UserProxySettings.fromJson(Map<String, dynamic>.from(raw));
        }
      case SiteField.javascriptEnabled:
        model.javascriptEnabled = value<bool>(field) ?? true;
      case SiteField.userAgent:
        // Migration: a stored string that is a stock webview-default shape
        // is a frozen snapshot of the device default (old settings-screen
        // builds pre-filled the field with the default and persisted it on
        // save). Drop the override so the site tracks the live default again.
        final userAgent = value<String>(field) ?? '';
        model.userAgent =
            isStockWebViewDefaultUserAgent(userAgent) ? '' : userAgent;
      case SiteField.uaPreset:
        // Migration: legacy data carries only the rendered string. A string
        // matching a generated shape (including shapes old buggy builds
        // emitted) gets its preset back here, so stale persisted UAs heal on
        // load instead of rotting until a site breaks on them.
        model.uaPreset = userAgentPresetFromName(value<String>(field)) ??
            recognizeGeneratedUserAgent(
                value<String>(SiteField.userAgent) ?? '');
      case SiteField.thirdPartyCookiesEnabled:
        model.thirdPartyCookiesEnabled = value<bool>(field) ?? false;
      case SiteField.httpsUpgradeEnabled:
        model.httpsUpgradeEnabled = value<bool>(field);
      case SiteField.incognito:
        model.incognito = incognito;
      case SiteField.alwaysOpenHome:
        model.alwaysOpenHome = alwaysOpenHome;
      case SiteField.kioskMode:
        model.kioskMode = value<bool>(field) ?? false;
      case SiteField.tabsEnabled:
        // Older saves omitted true; explicit null follows the app.
        model.tabsEnabled = json.containsKey(field.key) && raw == null
            ? null
            : value<bool>(field) ?? true;
      case SiteField.containerColor:
        model.containerColor = switch (value<int>(field)) {
          final int i when i >= 0 => i,
          _ => null,
        };
      case SiteField.language:
        model.language = sanitizedLanguageTag(raw);
      case SiteField.zoomPercent:
        model.zoomPercent = clampZoomPercent(
            finite(field)?.toInt() ?? kDefaultZoomPercent);
      case SiteField.theme:
        // A name this build does not know follows the app.
        model.theme = WebViewTheme.values.asNameMap()[raw];
      case SiteField.clearUrlEnabled:
        model.clearUrlEnabled = value<bool>(field) ?? true;
      case SiteField.dnsBlockEnabled:
        model.dnsBlockEnabled = value<bool>(field) ?? true;
      case SiteField.dnsBlockLevel:
        model.dnsBlockLevel = _readDnsBlockLevel(raw);
      case SiteField.disabledFilterLists:
        model.disabledFilterLists = {
          ...?value<List>(field)?.map(FilterListId.parse).nonNulls,
        };
      case SiteField.contentBlockEnabled:
        model.contentBlockEnabled = value<bool>(field) ?? true;
      case SiteField.trackingProtectionEnabled:
        model.trackingProtectionEnabled = value<bool>(field) ?? true;
      case SiteField.localCdnEnabled:
        model.localCdnEnabled = value<bool>(field) ?? true;
      case SiteField.externalLinkMode:
        // Older saves omitted inApp; explicit null follows the app.
        model.externalLinkMode = json.containsKey(field.key) && raw == null
            ? null
            : externalLinkModeFromJson(raw, legacyInBrowser: legacy(field));
      case SiteField.fullscreenMode:
        model.fullscreenMode = value<bool>(field) ?? false;
      case SiteField.blockScreenshots:
        model.blockScreenshots = value<bool>(field) ?? false;
      case SiteField.tabBarButtonCorner:
        // The short-lived bool predecessor of the four-corner field maps so
        // early builds rehydrate cleanly.
        model.tabBarButtonCorner =
            tabBarCornerFromName(value<String>(field)) ??
                switch (legacy(field)) {
                  true => TabBarCorner.bottomRight,
                  false => TabBarCorner.bottomLeft,
                  _ => null,
                };
      case SiteField.htmlCachingEnabled:
        model.htmlCachingEnabled = value<bool>(field) ?? false;
      case SiteField.notificationsEnabled:
        model.notificationsEnabled = value<bool>(field) ??
            switch (legacy(field)) {
              final bool poll => poll,
              _ => false,
            };
      case SiteField.backgroundAudioEnabled:
        model.backgroundAudioEnabled = value<bool>(field) ?? false;
      case SiteField.protectedContentAllowed:
        model.protectedContentAllowed = value<bool>(field);
      case SiteField.captures:
        model.captures = CaptureGrants.fromJson(json);
      case SiteField.userScripts:
        model.userScripts =
            _jsonEntries(raw, parse: UserScriptConfig.fromJson);
      case SiteField.enabledGlobalScriptIds:
        model.enabledGlobalScriptIds = {
          ...?value<List>(field)?.map(UserScriptId.parse).nonNulls,
        };
      case SiteField.blockedCookies:
        model.blockedCookies =
            _jsonEntries(raw, parse: BlockedCookie.tryFromJson).toSet();
      case SiteField.locationMode:
        model.locationMode = LocationMode.values.firstWhere(
          (m) => m.name == raw,
          orElse: () => LocationMode.off,
        );
      case SiteField.spoofLatitude:
        model.spoofLatitude = finite(field)?.toDouble();
      case SiteField.spoofLongitude:
        model.spoofLongitude = finite(field)?.toDouble();
      case SiteField.spoofAccuracy:
        model.spoofAccuracy =
            finite(field)?.toDouble() ?? kDefaultSpoofAccuracy;
      case SiteField.spoofTimezone:
        model.spoofTimezone = value<String>(field);
      case SiteField.spoofTimezoneFromLocation:
        model.spoofTimezoneFromLocation = value<bool>(field) ?? false;
      case SiteField.liveLocationGranularity:
        model.liveLocationGranularity = _decodeLiveLocationGranularity(raw);
      case SiteField.webRtcPolicy:
        model.webRtcPolicy = WebRtcPolicy.values.firstWhere(
          (p) => p.name == raw,
          orElse: () => WebRtcPolicy.defaultPolicy,
        );
      case SiteField.letterboxEnabled:
        model.letterboxEnabled = value<bool>(field) ?? false;
      case SiteField.spoofWindowWidth:
        model.spoofWindowWidth = finite(field)?.toInt();
      case SiteField.spoofWindowHeight:
        model.spoofWindowHeight = finite(field)?.toInt();
      case SiteField.fingerprintResetNonce:
        model.fingerprintResetNonce = value<String>(field);
      case SiteField.customIconPng:
        model.customIconPng = _decodeCustomIconPng(raw);
      case SiteField.domainClaims:
        // Absent stays null: no claims configured, as opposed to an emptied
        // list.
        model.domainClaims = raw is List
            ? [
                for (final claim
                    in _jsonEntries(raw, parse: DomainClaim.tryFromJson))
                  if (claim.value.isNotEmpty) claim,
              ]
            : null;
      case SiteField.routeOutboundLinks:
        model.routeOutboundLinks = json.containsKey(field.key) && raw == null
            ? null
            : value<bool>(field) ?? false;
      case SiteField.outboundPreferences:
        model.outboundPreferences = OutboundPreference.dedupedByClaim(
          (value<List<dynamic>>(field) ?? const [])
              .map(OutboundPreference.fromJson)
              .whereType<OutboundPreference>(),
        );
      case SiteField.searchAddress:
        model.searchAddress = value<String>(field);
      case SiteField.searchesWeb:
        model.searchesWeb = value<bool>(field) ?? false;
      case SiteField.discoveredSearchAddress:
        model.discoveredSearchAddress = value<String>(field);
      case SiteField.discoveredSearchesWeb:
        model.discoveredSearchesWeb = value<bool>(field) ?? false;
      case SiteField.searchSites:
        model.searchSites = [
          ...?value<List<dynamic>>(field)?.map(SiteId.parse).nonNulls,
        ];
      case SiteField.searchDefault:
        model.searchDefault = SiteId.parse(raw);
    }
  }
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
