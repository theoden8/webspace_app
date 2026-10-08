import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/services/cookie_manager.dart';

/// The persisted site list: the site JSON in SharedPreferences, each site's
/// cookies and proxy password in secure storage, keyed by `siteId`.
class SiteListStore {
  SiteListStore({required this.cookies, required this.proxyPasswords});

  final CookieSecureStorage cookies;
  final ProxyPasswordSecureStorage proxyPasswords;

  static const String _key = 'webViewModels';

  /// The persisted sites, migrated and hydrated. [needsResave] is true when
  /// sites were read: the migration (siteId-keyed cookies, schema
  /// normalization, dropped malformed sites) is applied in memory and is
  /// written back off the cold-start path, idempotently.
  Future<({List<WebViewModel> sites, bool needsResave})> load({
    required void Function() onChange,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final webViewModelsJson = prefs.getStringList(_key);

    if (webViewModelsJson == null) {
      return (sites: <WebViewModel>[], needsResave: false);
    }
    // Pre-pass: legacy data may carry a plaintext `password` field inside
    // each site's `proxySettings` blob. Move them into secure storage and
    // strip from the in-memory JSON before constructing models, so the
    // post-migration save writes the cleaned form back.
    final secureProxyPasswords = await proxyPasswords.loadAll();
    final legacyMigrations = <String, String>{};
    final cleanedJsonStrings = <String>[];
    for (var i = 0; i < webViewModelsJson.length; i++) {
      final raw = webViewModelsJson[i];
      try {
        final decoded = jsonDecode(raw) as Map<String, dynamic>;
        final proxy = decoded['proxySettings'];
        if (proxy is Map<String, dynamic>) {
          final pwd = proxy['password'];
          if (pwd is String && pwd.isNotEmpty) {
            final siteId = decoded['siteId'];
            if (siteId is String && siteId.isNotEmpty) {
              // Don't overwrite an existing secure-storage entry — the
              // secure value wins on conflict (it's newer by definition).
              if (!(secureProxyPasswords[siteId]?.isNotEmpty ?? false)) {
                legacyMigrations[siteId] = pwd;
              }
              proxy.remove('password');
            }
          }
        }
        cleanedJsonStrings.add(jsonEncode(decoded));
      } catch (e) {
        // The exception text can echo the malformed site JSON, which
        // includes initUrl / name — per-site identifiers. Memory ring.
        LogTag.boot.warning('Dropped unparseable site JSON at index $i: $e',
            sensitive: true);
      }
    }
    if (legacyMigrations.isNotEmpty) {
      await proxyPasswords.mutate((draft) {
        // Don't overwrite an existing secure entry — the migration guard
        // above only staged keys that were absent, so add-if-absent here.
        legacyMigrations.forEach((k, v) => draft.putIfAbsent(k, () => v));
      });
      await prefs.setStringList(_key, cleanedJsonStrings);
      secureProxyPasswords.addAll(legacyMigrations);
      LogTag.proxyPwdStore.info(
          'Migrated ${legacyMigrations.length} legacy plaintext per-site proxy password(s) to secure storage');
    }

    final loadedWebViewModels = <WebViewModel>[];
    for (var i = 0; i < cleanedJsonStrings.length; i++) {
      try {
        loadedWebViewModels.add(
          WebViewModel.fromJson(jsonDecode(cleanedJsonStrings[i]),
              stateSetterF: onChange),
        );
      } catch (e) {
        // Exception text can echo site JSON (initUrl / name). Memory ring.
        LogTag.boot.warning('Skipped malformed site at index $i: $e',
            sensitive: true);
      }
    }

    var hydratedCount = 0;
    var sitesWithCustomProxy = 0;
    for (final m in loadedWebViewModels) {
      if (m.proxySettings.type != ProxyType.DEFAULT) {
        sitesWithCustomProxy++;
      }
      final pwd = secureProxyPasswords[m.siteId];
      if (pwd != null && pwd.isNotEmpty) {
        m.proxySettings.password = pwd;
        hydratedCount++;
      }
    }
    LogTag.proxy.info('Hydrated proxy passwords for $hydratedCount of '
        '${loadedWebViewModels.length} site(s); '
        '$sitesWithCustomProxy site(s) have a non-DEFAULT per-site proxy',
        sensitive: true);

    final secureCookies = await cookies.loadCookies();
    // By siteId, falling back to the legacy domain key. Incognito sites
    // start each launch with no cookies, even when legacy entries exist in
    // secure storage from before the toggle was flipped on (issue #298).
    for (final webViewModel in loadedWebViewModels) {
      if (webViewModel.incognito) continue;
      var siteCookies = secureCookies[webViewModel.siteId];
      if (siteCookies == null || siteCookies.isEmpty) {
        final domain = extractDomain(webViewModel.initUrl);
        siteCookies = secureCookies[domain];
      }
      if (siteCookies != null && siteCookies.isNotEmpty) {
        webViewModel.cookies = siteCookies;
      }
    }
    return (sites: loadedWebViewModels, needsResave: true);
  }

  /// Writes the app-tier sites among [models]. Archive-tier sites are in
  /// [models] for runtime rendering but never enter app-tier persistence
  /// (ARCH-001 byte-identity): cookies, proxy passwords and the site JSON
  /// all filter on `!isArchiveTier`. [models] is read again inside the
  /// cookie store's lock, so pass the live list.
  Future<void> save(List<WebViewModel> models) async {
    final prefs = await SharedPreferences.getInstance();
    final appTierModels = models.where((m) => !m.isArchiveTier);

    // The cookie map is built INSIDE the store lock (ARCH-001): a concurrent
    // archive move flips isArchiveTier then clears the site's app-tier entry,
    // and a map snapshotted before that flip would re-persist the
    // archive-tier session here.
    await cookies.saveCookiesBuilt(() {
      final map = <String, List<Cookie>>{};
      for (final webViewModel in models.where((m) => !m.isArchiveTier)) {
        if (webViewModel.cookies.isNotEmpty && !webViewModel.incognito) {
          map[webViewModel.siteId] = List.from(webViewModel.cookies);
        }
      }
      return map;
    });

    // The non-secret proxy fields ride in the site JSON; `toJson()` omits
    // the password, which lives in secure storage.
    await proxyPasswords.mutate((draft) {
      for (final m in appTierModels) {
        draft[m.siteId] = m.proxySettings.password;
      }
    });

    final webViewModelsJson = appTierModels.map((webViewModel) {
      final json = webViewModel.toJson();
      json['cookies'] = [];
      return jsonEncode(json);
    }).toList();
    await prefs.setStringList(_key, webViewModelsJson);
  }
}
