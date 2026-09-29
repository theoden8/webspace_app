import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/proxy.dart';

/// SharedPreferences key holding the saved proxies as a JSON list. Registered
/// in `kExportedAppPrefs`, so the list rides backups; each password stays in
/// secure storage and never does (PWD-005, PWD-007).
const String kSavedProxiesKey = 'savedProxies';

const String kSavedProxiesDefault = '[]';

/// The proxy types a saved proxy may carry. Tor is one built-in route with
/// per-site circuits, not a configuration to share, and DEFAULT or SAVED
/// would make a saved proxy name another route instead of being one.
const Set<ProxyType> kSavedProxyTypes = {
  ProxyType.HTTP,
  ProxyType.HTTPS,
  ProxyType.SOCKS5,
};

/// A proxy configured once and named by any number of sites (PROXY-029).
class SavedProxy {
  SavedProxy({
    required this.id,
    required this.name,
    required this.settings,
  });

  /// Stable, random, never shown. Sites store this, so a rename does not
  /// break them.
  final String id;
  String name;

  /// Always one of [kSavedProxyTypes].
  UserProxySettings settings;

  /// The password is left out, as for every other proxy (PWD-005).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'proxy': settings.toJson(),
      };

  /// Null for an entry that cannot be used: no id, or a type a saved proxy
  /// may not have. Dropping it leaves the sites that named it unresolved,
  /// which fails closed.
  ///
  /// A password is never read from JSON: the list arrives from backups,
  /// which are hand-editable, and a password in one can only have been
  /// written there to point this device's traffic at someone else's proxy
  /// (BACKUP-011).
  static SavedProxy? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final proxy = json['proxy'];
    if (id is! String || id.isEmpty || proxy is! Map) return null;
    final settings =
        UserProxySettings.fromJson(Map<String, dynamic>.from(proxy));
    if (!kSavedProxyTypes.contains(settings.type)) return null;
    settings
      ..password = null
      ..torExitCountry = null
      ..savedProxyId = null;
    return SavedProxy(
      id: id,
      name: name is String ? name : '',
      settings: settings,
    );
  }

  SavedProxy copy() => SavedProxy(
        id: id,
        name: name,
        settings: UserProxySettings(
          type: settings.type,
          address: settings.address,
          username: settings.username,
          password: settings.password,
        ),
      );

  static String newId() {
    final random = Random.secure();
    return List.generate(16, (_) => random.nextInt(16).toRadixString(16))
        .join();
  }
}

/// Decode [kSavedProxiesKey]. Unusable entries and duplicate ids are
/// dropped; a malformed value reads as no saved proxies.
List<SavedProxy> readSavedProxies(SharedPreferences prefs) =>
    decodeSavedProxies(readPrefAs<String>(prefs, kSavedProxiesKey));

List<SavedProxy> decodeSavedProxies(Object? raw) {
  if (raw is! String || raw.isEmpty) return [];
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return [];
  }
  if (decoded is! List) return [];
  final seen = <String>{};
  final out = <SavedProxy>[];
  for (final entry in decoded) {
    final proxy = SavedProxy.fromJson(entry);
    if (proxy == null || !seen.add(proxy.id)) continue;
    out.add(proxy);
  }
  return out;
}

String encodeSavedProxies(List<SavedProxy> proxies) =>
    jsonEncode([for (final p in proxies) p.toJson()]);

/// In-memory copy of the saved proxies, loaded once at startup so that
/// `resolveEffectiveProxy` can stay synchronous. Same shape as
/// `GlobalOutboundProxy`.
class SavedProxies {
  SavedProxies._();

  static List<SavedProxy> _all = const [];

  static List<SavedProxy> get all => List.unmodifiable(_all);

  static SavedProxy? byId(String? id) {
    if (id == null) return null;
    for (final p in _all) {
      if (p.id == id) return p;
    }
    return null;
  }

  static ProxyPasswordSecureStorage _passwordStore =
      ProxyPasswordSecureStorage();

  static void setPasswordStoreForTest(ProxyPasswordSecureStorage store) {
    _passwordStore = store;
  }

  /// Load from SharedPreferences and hydrate passwords. Call at startup
  /// before anything resolves a proxy.
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final loaded = readSavedProxies(prefs);
    final passwords = await _passwordStore.loadAll();
    for (final p in loaded) {
      final pwd = passwords[ProxyPasswordSecureStorage.savedProxyKey(p.id)];
      if (pwd != null && pwd.isNotEmpty) p.settings.password = pwd;
    }
    _all = loaded;
    await _dropOrphanedPasswords();
    LogService.instance.log(
      'Proxy',
      'SavedProxies initialized: ${_all.length} saved',
      level: LogLevel.info,
    );
  }

  /// Replace the whole list: persist the non-secret fields, write each
  /// password to secure storage, and delete the passwords of proxies that
  /// are gone.
  static Future<void> update(List<SavedProxy> proxies) async {
    _all = [for (final p in proxies) p.copy()];
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kSavedProxiesKey, encodeSavedProxies(_all));
    await _passwordStore.mutate((draft) {
      draft.removeWhere(
          (key, _) => ProxyPasswordSecureStorage.isSavedProxyKey(key));
      for (final p in _all) {
        final pwd = p.settings.password;
        if (pwd != null && pwd.isNotEmpty) {
          draft[ProxyPasswordSecureStorage.savedProxyKey(p.id)] = pwd;
        }
      }
    });
    LogService.instance.log(
      'Proxy',
      'SavedProxies updated: ${_all.map((p) => '${p.id}=${p.settings.describeForLogs()}').join('; ')}',
      level: LogLevel.info,
      sensitivity: LogSensitivity.sensitive,
    );
  }

  /// Re-read the list an import just wrote. An import carries no password
  /// (PWD-005), so none survives it, as for per-site and app-wide proxies.
  static Future<void> reloadAfterImport() async {
    final prefs = await SharedPreferences.getInstance();
    await update(readSavedProxies(prefs));
  }

  static Future<void> _dropOrphanedPasswords() async {
    final keep = {
      for (final p in _all) ProxyPasswordSecureStorage.savedProxyKey(p.id),
    };
    await _passwordStore.mutate((draft) {
      draft.removeWhere((key, _) =>
          ProxyPasswordSecureStorage.isSavedProxyKey(key) &&
          !keep.contains(key));
    });
  }

  /// Replace the list in memory only, persisting nothing: for tests and the
  /// design gallery.
  static void setInMemory(List<SavedProxy> proxies) {
    _all = [for (final p in proxies) p.copy()];
  }

  static void resetForTest() {
    _all = const [];
  }
}

/// What [settings] names once a saved proxy is looked up: the saved proxy's
/// configuration under [ProxyType.SAVED], [settings] unchanged otherwise.
///
/// A name that resolves to nothing (the proxy was deleted, or the reference
/// came from another device) stays [ProxyType.SAVED] with no address. Every
/// seam treats a proxied type without an address as unroutable, so the site
/// is blocked rather than sent direct or through the app-wide proxy, either
/// of which would be a route the user did not pick.
UserProxySettings resolveSavedProxy(UserProxySettings settings) {
  if (settings.type != ProxyType.SAVED) return settings;
  final saved = SavedProxies.byId(settings.savedProxyId);
  if (saved == null) {
    return UserProxySettings(
      type: ProxyType.SAVED,
      savedProxyId: settings.savedProxyId,
    );
  }
  return UserProxySettings(
    type: saved.settings.type,
    address: saved.settings.address,
    username: saved.settings.username,
    password: saved.settings.password,
  );
}
