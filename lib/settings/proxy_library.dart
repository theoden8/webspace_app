import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/pref_read.dart';
import 'package:webspace/settings/proxy.dart';

/// SharedPreferences key holding the proxy library as one JSON object:
/// `{gateways, credentials, proxies}`. Registered in `kExportedAppPrefs`, so
/// it rides backups; every password stays in secure storage and never does
/// (PWD-005, PWD-007).
const String kProxyLibraryKey = 'proxyLibrary';

const String kProxyLibraryDefault = '{}';

/// The types a gateway may have. Tor is one built-in route with per-site
/// circuits, not an endpoint to share, and DEFAULT, SAVED and GATEWAY name
/// routes rather than being one.
const Set<ProxyType> kGatewayTypes = {
  ProxyType.HTTP,
  ProxyType.HTTPS,
  ProxyType.SOCKS5,
};

String _newId() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
}

String? _text(Object? v) => v is String ? v : null;

/// A proxy endpoint: type and `host:port`, named so sites and saved proxies
/// can share it.
class SavedGateway {
  SavedGateway({
    required this.id,
    required this.name,
    required this.type,
    this.address,
  });

  final String id;
  String name;

  /// One of [kGatewayTypes].
  ProxyType type;
  String? address;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.index,
        'address': address,
      };

  static SavedGateway? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    if (id == null || id.isEmpty) return null;
    final type = UserProxySettings.fromJson({'type': json['type']}).type;
    if (!kGatewayTypes.contains(type)) return null;
    return SavedGateway(
      id: id,
      name: _text(json['name']) ?? '',
      type: type,
      address: _text(json['address']),
    );
  }

  SavedGateway copy() =>
      SavedGateway(id: id, name: name, type: type, address: address);

  static String newId() => _newId();
}

/// A username and password, and the saved gateways they are valid on. A site
/// or saved proxy can use them only with one of those gateways.
class SavedCredentials {
  SavedCredentials({
    required this.id,
    required this.name,
    this.username,
    this.password,
    Set<String>? gatewayIds,
  }) : gatewayIds = gatewayIds ?? {};

  final String id;
  String name;
  String? username;

  /// Hydrated from secure storage; never serialized.
  String? password;
  Set<String> gatewayIds;

  bool fits(String? gatewayId) =>
      gatewayId != null && gatewayIds.contains(gatewayId);

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'username': username,
        'gatewayIds': gatewayIds.toList()..sort(),
      };

  /// A password is never read from JSON: the library arrives from backups,
  /// which are hand-editable, and a password in one can only have been
  /// written there to point this device's traffic at someone else's proxy
  /// (BACKUP-011).
  static SavedCredentials? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    if (id == null || id.isEmpty) return null;
    final ids = json['gatewayIds'];
    return SavedCredentials(
      id: id,
      name: _text(json['name']) ?? '',
      username: _text(json['username']),
      gatewayIds: {
        if (ids is List)
          for (final g in ids)
            if (g is String && g.isNotEmpty) g,
      },
    );
  }

  SavedCredentials copy() => SavedCredentials(
        id: id,
        name: name,
        username: username,
        password: password,
        gatewayIds: {...gatewayIds},
      );

  static String newId() => _newId();
}

/// A named route: a gateway (typed, or a saved one) and credentials (typed,
/// saved ones that fit the gateway, or none). With both typed it is simply a
/// proxy; the library entries matter only when something is shared
/// (PROXY-029).
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

  /// One of [kGatewayTypes] with a typed address, or [ProxyType.GATEWAY];
  /// credentials typed or by [UserProxySettings.credentialsId].
  UserProxySettings settings;

  static bool validType(ProxyType t) =>
      kGatewayTypes.contains(t) || t == ProxyType.GATEWAY;

  /// The password is left out, as for every other proxy (PWD-005).
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'proxy': settings.toJson(),
      };

  /// Null for an entry that cannot be used: no id, or a type a saved proxy
  /// may not have. Dropping it leaves the sites that named it unresolved,
  /// which fails closed. A password is never read, as for credentials.
  static SavedProxy? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = _text(json['id']);
    final proxy = json['proxy'];
    if (id == null || id.isEmpty || proxy is! Map) return null;
    final settings =
        UserProxySettings.fromJson(Map<String, dynamic>.from(proxy));
    if (!validType(settings.type)) return null;
    settings
      ..password = null
      ..torExitCountry = null
      ..savedProxyId = null;
    return SavedProxy(
      id: id,
      name: _text(json['name']) ?? '',
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
          gatewayId: settings.gatewayId,
          credentialsId: settings.credentialsId,
        ),
      );

  static String newId() => _newId();
}

/// The whole library, as it is stored and edited.
class ProxyLibraryData {
  ProxyLibraryData({
    List<SavedGateway>? gateways,
    List<SavedCredentials>? credentials,
    List<SavedProxy>? proxies,
  })  : gateways = gateways ?? [],
        credentials = credentials ?? [],
        proxies = proxies ?? [];

  final List<SavedGateway> gateways;
  final List<SavedCredentials> credentials;
  final List<SavedProxy> proxies;

  bool get isEmpty => gateways.isEmpty && credentials.isEmpty && proxies.isEmpty;
  int get length => gateways.length + credentials.length + proxies.length;

  SavedGateway? gateway(String? id) => _find(gateways, id, (g) => g.id);
  SavedCredentials? credentialsById(String? id) =>
      _find(credentials, id, (c) => c.id);
  SavedProxy? proxy(String? id) => _find(proxies, id, (p) => p.id);

  static T? _find<T>(List<T> list, String? id, String Function(T) idOf) {
    if (id == null) return null;
    for (final e in list) {
      if (idOf(e) == id) return e;
    }
    return null;
  }

  /// Credentials that can sign in on [gatewayId].
  List<SavedCredentials> credentialsFor(String? gatewayId) =>
      [for (final c in credentials) if (c.fits(gatewayId)) c];

  ProxyLibraryData copy() => ProxyLibraryData(
        gateways: [for (final g in gateways) g.copy()],
        credentials: [for (final c in credentials) c.copy()],
        proxies: [for (final p in proxies) p.copy()],
      );

  /// Remove a gateway, and with it from every credentials entry's list.
  /// What still names it (saved proxies, sites) fails closed.
  void removeGateway(String id) {
    gateways.removeWhere((g) => g.id == id);
    for (final c in credentials) {
      c.gatewayIds.remove(id);
    }
  }

  Map<String, dynamic> toJson() => {
        'gateways': [for (final g in gateways) g.toJson()],
        'credentials': [for (final c in credentials) c.toJson()],
        'proxies': [for (final p in proxies) p.toJson()],
      };

  String encode() => jsonEncode(toJson());

  /// Unusable entries and duplicate ids are dropped; a malformed value reads
  /// as an empty library.
  static ProxyLibraryData decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return ProxyLibraryData();
    Object? json;
    try {
      json = jsonDecode(raw);
    } catch (_) {
      return ProxyLibraryData();
    }
    if (json is! Map) return ProxyLibraryData();
    List<T> list<T>(String key, T? Function(Object?) parse, String Function(T) idOf) {
      final value = json is Map ? json[key] : null;
      if (value is! List) return [];
      final seen = <String>{};
      return [
        for (final e in value.map(parse))
          if (e != null && seen.add(idOf(e))) e,
      ];
    }

    return ProxyLibraryData(
      gateways: list('gateways', SavedGateway.fromJson, (g) => g.id),
      credentials: list('credentials', SavedCredentials.fromJson, (c) => c.id),
      proxies: list('proxies', SavedProxy.fromJson, (p) => p.id),
    );
  }
}

ProxyLibraryData readProxyLibrary(SharedPreferences prefs) =>
    ProxyLibraryData.decode(readPrefAs<String>(prefs, kProxyLibraryKey));

/// In-memory copy of the library, loaded once at startup so that
/// `resolveEffectiveProxy` can stay synchronous. Same shape as
/// `GlobalOutboundProxy`.
class ProxyLibrary {
  ProxyLibrary._();

  static ProxyLibraryData _data = ProxyLibraryData();

  /// A copy: edit it and hand it to [update].
  static ProxyLibraryData get data => _data.copy();

  static List<SavedProxy> get proxies => List.unmodifiable(_data.proxies);
  static List<SavedGateway> get gateways => List.unmodifiable(_data.gateways);
  static List<SavedCredentials> get credentials =>
      List.unmodifiable(_data.credentials);

  static SavedProxy? proxy(String? id) => _data.proxy(id);
  static SavedGateway? gateway(String? id) => _data.gateway(id);
  static SavedCredentials? credentialsById(String? id) =>
      _data.credentialsById(id);

  static ProxyPasswordSecureStorage _passwordStore =
      ProxyPasswordSecureStorage();

  static void setPasswordStoreForTest(ProxyPasswordSecureStorage store) {
    _passwordStore = store;
  }

  /// Load from SharedPreferences and hydrate passwords. Call at startup
  /// before anything resolves a proxy.
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final loaded = readProxyLibrary(prefs);
    final passwords = await _passwordStore.loadAll();
    for (final c in loaded.credentials) {
      c.password =
          passwords[ProxyPasswordSecureStorage.savedCredentialsKey(c.id)];
    }
    for (final p in loaded.proxies) {
      p.settings.password =
          passwords[ProxyPasswordSecureStorage.savedProxyKey(p.id)];
    }
    _data = loaded;
    await _writePasswords();
    LogService.instance.log(
      'Proxy',
      'ProxyLibrary initialized: ${loaded.gateways.length} gateways, '
          '${loaded.credentials.length} credentials, '
          '${loaded.proxies.length} proxies',
      level: LogLevel.info,
    );
  }

  /// Replace the whole library: persist the non-secret fields, write each
  /// password to secure storage, and delete the passwords of entries that
  /// are gone.
  static Future<void> update(ProxyLibraryData next) async {
    _data = next.copy();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kProxyLibraryKey, _data.encode());
    await _writePasswords();
    LogService.instance.log(
      'Proxy',
      'ProxyLibrary updated: ${_data.gateways.length} gateways, '
          '${_data.credentials.length} credentials, '
          '${_data.proxies.length} proxies',
      level: LogLevel.info,
    );
  }

  /// Re-read the library an import just wrote. An import carries no password
  /// (PWD-005), so none survives it, as for per-site and app-wide proxies.
  static Future<void> reloadAfterImport() async {
    final prefs = await SharedPreferences.getInstance();
    await update(readProxyLibrary(prefs));
  }

  /// Secure storage holds exactly the library's passwords afterwards, which
  /// also collects the orphans of entries deleted before a crash.
  static Future<void> _writePasswords() async {
    await _passwordStore.mutate((draft) {
      draft.removeWhere(
          (key, _) => ProxyPasswordSecureStorage.isLibraryKey(key));
      for (final c in _data.credentials) {
        final pwd = c.password;
        if (pwd != null && pwd.isNotEmpty) {
          draft[ProxyPasswordSecureStorage.savedCredentialsKey(c.id)] = pwd;
        }
      }
      for (final p in _data.proxies) {
        final pwd = p.settings.password;
        if (pwd != null && pwd.isNotEmpty) {
          draft[ProxyPasswordSecureStorage.savedProxyKey(p.id)] = pwd;
        }
      }
    });
  }

  /// Replace the library in memory only, persisting nothing: for tests and
  /// the design gallery.
  static void setInMemory(ProxyLibraryData data) {
    _data = data.copy();
  }

  static void resetForTest() {
    _data = ProxyLibraryData();
  }
}

/// Why a setting that uses the library has no route.
enum LibraryProblem {
  none,
  proxyMissing,
  gatewayMissing,
  credentialsMissing,

  /// The credentials do not list the gateway they are paired with.
  credentialsMismatch,
}

class LibraryResolution {
  const LibraryResolution(this.route, [this.problem = LibraryProblem.none]);

  /// Concrete settings, or [ProxyType.SAVED] with no address when
  /// [problem] is set.
  final UserProxySettings route;
  final LibraryProblem problem;

  static LibraryResolution failed(LibraryProblem p) =>
      LibraryResolution(UserProxySettings(type: ProxyType.SAVED), p);
}

/// Resolve what [settings] takes from the library against [library]
/// (defaults to [ProxyLibrary]'s). Settings that take nothing from it come
/// back unchanged.
///
/// Anything that does not resolve (a deleted entry, a reference from another
/// device, credentials paired with a gateway they do not list) comes back as
/// [ProxyType.SAVED] with no address. Every seam treats a proxied type
/// without an address as unroutable, so the site is blocked rather than sent
/// direct or through the app-wide proxy, either of which would be a route the
/// user did not pick.
LibraryResolution resolveLibrary(
  UserProxySettings settings, [
  ProxyLibraryData? library,
]) {
  final lib = library ?? ProxyLibrary._data;
  if (settings.type == ProxyType.SAVED) {
    final proxy = lib.proxy(settings.savedProxyId);
    if (proxy == null) {
      return LibraryResolution.failed(LibraryProblem.proxyMissing);
    }
    return _resolveChoices(proxy.settings, lib);
  }
  if (settings.type == ProxyType.GATEWAY ||
      (kGatewayTypes.contains(settings.type) &&
          settings.credentialsId != null)) {
    return _resolveChoices(settings, lib);
  }
  return LibraryResolution(settings);
}

LibraryResolution _resolveChoices(
  UserProxySettings s,
  ProxyLibraryData lib,
) {
  ProxyType type;
  String? address;
  if (s.type == ProxyType.GATEWAY) {
    final gateway = lib.gateway(s.gatewayId);
    if (gateway == null) {
      return LibraryResolution.failed(LibraryProblem.gatewayMissing);
    }
    type = gateway.type;
    address = gateway.address;
  } else if (kGatewayTypes.contains(s.type)) {
    type = s.type;
    address = s.address;
  } else {
    return LibraryResolution.failed(LibraryProblem.proxyMissing);
  }
  var username = s.username;
  var password = s.password;
  if (s.credentialsId != null) {
    final credentials = lib.credentialsById(s.credentialsId);
    if (credentials == null) {
      return LibraryResolution.failed(LibraryProblem.credentialsMissing);
    }
    // A typed gateway is in no credentials entry's list.
    if (s.type != ProxyType.GATEWAY || !credentials.fits(s.gatewayId)) {
      return LibraryResolution.failed(LibraryProblem.credentialsMismatch);
    }
    username = credentials.username;
    password = credentials.password;
  }
  return LibraryResolution(UserProxySettings(
    type: type,
    address: address,
    username: username,
    password: password,
  ));
}

/// [resolveLibrary] without the reason.
UserProxySettings resolveLibraryProxy(UserProxySettings settings) =>
    resolveLibrary(settings).route;

/// Whether [settings] uses the library entry [id] of [kind], directly or
/// through a saved proxy. What deleting that entry would block.
bool usesLibraryEntry(
  UserProxySettings settings,
  LibraryEntryKind kind,
  String id,
  ProxyLibraryData lib,
) {
  if (settings.type == ProxyType.SAVED) {
    if (kind == LibraryEntryKind.proxy) return settings.savedProxyId == id;
    final proxy = lib.proxy(settings.savedProxyId);
    return proxy != null && usesLibraryEntry(proxy.settings, kind, id, lib);
  }
  return switch (kind) {
    LibraryEntryKind.proxy => false,
    LibraryEntryKind.gateway =>
      settings.type == ProxyType.GATEWAY && settings.gatewayId == id,
    LibraryEntryKind.credentials =>
      settings.credentialsId == id &&
          (settings.type == ProxyType.GATEWAY ||
              kGatewayTypes.contains(settings.type)),
  };
}

enum LibraryEntryKind { proxy, gateway, credentials }
