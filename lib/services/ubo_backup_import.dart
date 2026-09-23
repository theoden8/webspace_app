/// Reads a uBlock Origin backup (the `my-ublock-backup_*.txt` file its
/// dashboard saves) into a plan the content blocker can apply.
///
/// The field set and the acceptance test mirror uBO's own restore path
/// (`backupUserData` in `messaging.js`, the file check in `settings.js`).
/// Only what this app's engine can express is planned: filter lists, the
/// user's own filters, and trusted sites that name a whole host. uBO's
/// dynamic filtering, URL rules and per-site switches have no counterpart;
/// they are counted so the user is told what stayed behind.
library;

import 'dart:convert';

/// uBO's asset registry lives here; list keys in a backup resolve through it.
const String kUboAssetRegistryUrl =
    'https://raw.githubusercontent.com/gorhill/uBlock/master/assets/assets.json';

/// uBO's key for the user's own filters in `selectedFilterLists`.
const String _kUserFiltersKey = 'user-filters';

class UboBackup {
  /// List keys (`easylist`, `ublock-filters`) and URLs of imported lists,
  /// in backup order.
  final List<String> selectedLists;
  final String userFilters;
  final List<String> trustedDirectives;

  /// Rules in uBO-only sections, beyond uBO's own defaults.
  final int dynamicRuleCount;
  final int urlRuleCount;
  final int switchRuleCount;

  const UboBackup({
    required this.selectedLists,
    required this.userFilters,
    required this.trustedDirectives,
    this.dynamicRuleCount = 0,
    this.urlRuleCount = 0,
    this.switchRuleCount = 0,
  });

  /// Null when [text] is not a uBO backup. Accepts what uBO's restore
  /// accepts: an object with `userSettings`, a trusted-site list (array or
  /// the older newline string) and a list selection (array or the older
  /// `filterLists` map).
  static UboBackup? parse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final d = decoded;
    if (d['userSettings'] is! Map) return null;
    final whitelist = d['whitelist'];
    final netWhitelist = d['netWhitelist'];
    if (whitelist is! List && netWhitelist is! String) return null;
    final selected = d['selectedFilterLists'];
    final legacyLists = d['filterLists'];
    if (selected is! List && legacyLists is! Map) return null;

    final lists = <String>[];
    if (selected is List) {
      lists.addAll(selected.whereType<String>());
    } else if (legacyLists is Map) {
      for (final entry in legacyLists.entries) {
        final v = entry.value;
        if (entry.key is String && !(v is Map && v['off'] == true)) {
          lists.add(entry.key as String);
        }
      }
    }
    // Older backups list imported URLs separately.
    for (final field in const ['externalLists', 'importedLists']) {
      for (final url in _lines(d[field])) {
        if (!lists.contains(url)) lists.add(url);
      }
    }

    final trusted = whitelist is List
        ? whitelist.whereType<String>().toList()
        : _lines(netWhitelist);

    return UboBackup(
      selectedLists: lists,
      userFilters: _lines(d['userFilters'], keepBlank: true).join('\n').trim(),
      trustedDirectives: trusted,
      dynamicRuleCount: _lines(d['dynamicFilteringString'])
          .where((l) => !l.startsWith('behind-the-scene '))
          .length,
      urlRuleCount: _lines(d['urlFilteringString']).length,
      switchRuleCount: _lines(d['hostnameSwitchesString'])
          .where((l) =>
              !l.contains(' behind-the-scene ') && l != 'no-csp-reports: * true')
          .length,
    );
  }

  int get droppedRuleCount => dynamicRuleCount + urlRuleCount + switchRuleCount;
}

List<String> _lines(Object? v, {bool keepBlank = false}) {
  final raw = v is List
      ? v.whereType<String>()
      : v is String
          ? v.split('\n')
          : const <String>[];
  return [
    for (final l in raw)
      if (keepBlank || l.trim().isNotEmpty) keepBlank ? l : l.trim()
  ];
}

class UboAsset {
  final String title;
  final String url;
  const UboAsset(this.title, this.url);
}

/// Filter lists in uBO's `assets.json`, keyed as backups name them. The
/// first remote `contentURL` is taken; the bundled `assets/...` copies are
/// uBO-internal paths.
Map<String, UboAsset> parseUboAssetRegistry(String text) {
  final out = <String, UboAsset>{};
  final decoded = jsonDecode(text);
  if (decoded is! Map<String, dynamic>) return out;
  for (final entry in decoded.entries) {
    final v = entry.value;
    if (v is! Map || v['content'] != 'filters') continue;
    final urls = v['contentURL'];
    final candidates = urls is List ? urls.whereType<String>() : [if (urls is String) urls];
    final url = candidates.where((u) => u.startsWith('https://')).firstOrNull;
    if (url == null) continue;
    final title = v['title'];
    out[entry.key] = UboAsset(title is String ? title : entry.key, url);
  }
  return out;
}

/// What the app already has, as far as planning needs. A local list has
/// an empty URL.
class ExistingFilterList {
  final String id;
  final String url;
  const ExistingFilterList(this.id, this.url);
}

class PlannedList {
  final String name;
  final String url;
  const PlannedList(this.name, this.url);
}

class UboImportPlan {
  /// Lists the app already has that the backup selects.
  final List<String> enableIds;
  final List<PlannedList> addLists;

  /// Keys the registry could not resolve (offline, or retired by uBO).
  final List<String> unresolvedKeys;

  /// The user's own filters, or null when the backup carries none.
  final String? userFilters;
  final bool userFiltersEnabled;

  /// Hosts whose sites get the content blocker switched off.
  final Set<String> trustedHosts;

  /// Trusted-site directives narrower or wider than a host (a path, a
  /// regex): a per-site toggle cannot express them.
  final List<String> unsupportedTrusted;

  final int droppedRuleCount;

  const UboImportPlan({
    required this.enableIds,
    required this.addLists,
    required this.unresolvedKeys,
    required this.userFilters,
    required this.userFiltersEnabled,
    required this.trustedHosts,
    required this.unsupportedTrusted,
    required this.droppedRuleCount,
  });

  bool get isEmpty =>
      enableIds.isEmpty &&
      addLists.isEmpty &&
      userFilters == null &&
      trustedHosts.isEmpty;
}

UboImportPlan planUboImport(
  UboBackup backup, {
  required List<ExistingFilterList> existing,
  required Map<String, UboAsset> registry,
}) {
  final byId = {for (final l in existing) l.id: l};
  final byUrl = {
    for (final l in existing)
      if (l.url.isNotEmpty) l.url: l
  };
  final enable = <String>[];
  final add = <PlannedList>[];
  final addedUrls = <String>{};
  final unresolved = <String>[];

  void want(String url, String name) {
    final have = byUrl[url];
    if (have != null) {
      if (!enable.contains(have.id)) enable.add(have.id);
    } else if (addedUrls.add(url)) {
      add.add(PlannedList(name, url));
    }
  }

  for (final key in backup.selectedLists) {
    if (key == _kUserFiltersKey) continue;
    final uri = Uri.tryParse(key);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      want(key, uri.pathSegments.where((s) => s.isNotEmpty).lastOrNull ?? uri.host);
      continue;
    }
    // The built-in lists share uBO's keys (easylist, easyprivacy,
    // fanboy-social), so a key the app already has wins over a mirror URL.
    final same = byId[key];
    if (same != null) {
      if (!enable.contains(same.id)) enable.add(same.id);
      continue;
    }
    final asset = registry[key];
    if (asset == null) {
      unresolved.add(key);
      continue;
    }
    want(asset.url, asset.title);
  }

  final trusted = <String>{};
  final unsupported = <String>[];
  for (final raw in backup.trustedDirectives) {
    final d = raw.trim();
    if (d.isEmpty || d.startsWith('#')) continue;
    if (d.endsWith('-scheme')) continue;
    final host = trustedHostOf(d);
    if (host == null) {
      unsupported.add(d);
    } else {
      trusted.add(host);
    }
  }

  return UboImportPlan(
    enableIds: enable,
    addLists: add,
    unresolvedKeys: unresolved,
    userFilters: backup.userFilters.isEmpty ? null : backup.userFilters,
    userFiltersEnabled: backup.selectedLists.contains(_kUserFiltersKey),
    trustedHosts: trusted,
    unsupportedTrusted: unsupported,
    droppedRuleCount: backup.droppedRuleCount,
  );
}

final RegExp _kHostPattern =
    RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$');

/// The host a trusted-site directive covers whole, or null when it names
/// less (a path) or something else (a regex, a wildcard host).
String? trustedHostOf(String directive) {
  var d = directive.trim().toLowerCase();
  if (d.startsWith('/') && d.endsWith('/')) return null;
  final scheme = d.indexOf('://');
  if (scheme >= 0) {
    d = d.substring(scheme + 3);
    final slash = d.indexOf('/');
    if (slash >= 0) {
      final path = d.substring(slash);
      if (path != '/' && path != '/*') return null;
      d = d.substring(0, slash);
    }
  }
  return _kHostPattern.hasMatch(d) ? d : null;
}

/// A site a uBO trusted-site directive reaches.
class UboTrustedSite {
  final String name;
  final String host;
  const UboTrustedSite(this.name, this.host);
}

/// Sites a trusted host covers. uBO's hostname directive covers
/// subdomains, so `example.com` trusts `www.example.com` too.
bool hostTrustedBy(String siteHost, Set<String> trustedHosts) {
  final h = siteHost.toLowerCase();
  for (final t in trustedHosts) {
    if (h == t || h.endsWith('.$t')) return true;
  }
  return false;
}
