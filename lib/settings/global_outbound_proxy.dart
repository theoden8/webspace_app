import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/proxy.dart';

/// Global outbound-proxy settings: applied to every Dart-side HTTP call that
/// is *not* tied to a specific site (DNS blocklist download, ClearURLs rules,
/// content blocker rules, LocalCDN catalog, OSM map tiles in the location
/// picker, …). Per-site outbound calls (favicons, downloads, user-script
/// fetches) use the *site's* proxy, not this one.
///
/// Stored as a JSON-encoded [UserProxySettings] in SharedPreferences (the
/// non-secret fields only). The password lives in `flutter_secure_storage`
/// via [ProxyPasswordSecureStorage], keyed by
/// [ProxyPasswordSecureStorage.globalProxyKey], and is hydrated into the
/// in-memory [_current] at app startup. The SharedPreferences key is still
/// registered in [kExportedAppPrefs] so the non-secret fields round-trip
/// through the settings backup format; the password is intentionally NOT
/// included in the export (PWD-005) — same contract as `isSecure=true`
/// cookies, see `openspec/specs/proxy-password-secure-storage/spec.md`.
const String kGlobalOutboundProxyKey = 'globalOutboundProxy';

/// Default-encoded value for [kGlobalOutboundProxyKey] (DEFAULT proxy type,
/// no address). Kept as a constant string so the [kExportedAppPrefs] registry
/// can declare a primitive default.
final String kGlobalOutboundProxyDefault =
    jsonEncode(UserProxySettings(type: ProxyType.DEFAULT).toJson());

/// In-memory cache of the global outbound proxy. Initialized by
/// [GlobalOutboundProxy.initialize] at app startup so synchronous callers
/// (e.g. flutter_map's tile provider) don't have to await SharedPreferences.
class GlobalOutboundProxy {
  GlobalOutboundProxy._();

  static UserProxySettings _current = UserProxySettings(type: ProxyType.DEFAULT);

  /// Currently-applied global outbound proxy.
  static UserProxySettings get current => _current;

  /// Secure-storage handle for the password component. Tests may override.
  static ProxyPasswordSecureStorage _passwordStore =
      ProxyPasswordSecureStorage();

  /// Override the password store; for tests.
  static void setPasswordStoreForTest(ProxyPasswordSecureStorage store) {
    _passwordStore = store;
  }

  /// Load the persisted value from SharedPreferences. Call once at startup,
  /// after `SharedPreferences.getInstance()` is available.
  ///
  /// Performs a one-shot migration of any legacy plaintext password found
  /// under [kGlobalOutboundProxyKey] into secure storage.
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    await _passwordStore.migrateLegacyPassword(
      prefs: prefs,
      prefsKey: kGlobalOutboundProxyKey,
      secureKey: ProxyPasswordSecureStorage.globalProxyKey,
    );
    _current = readGlobalOutboundProxy(prefs);
    final pwd = await _passwordStore
        .loadPassword(ProxyPasswordSecureStorage.globalProxyKey);
    if (pwd != null && pwd.isNotEmpty) {
      _current.password = pwd;
    }
    LogService.instance.log(
      'Proxy',
      'GlobalOutboundProxy initialized: ${_current.describeForLogs()}',
      level: LogLevel.info,
    );
  }

  /// Update both the in-memory cache and the persisted value.
  static Future<void> update(UserProxySettings settings) async {
    _current = settings;
    final prefs = await SharedPreferences.getInstance();
    await writeGlobalOutboundProxy(prefs, settings);
    await _passwordStore.savePassword(
      ProxyPasswordSecureStorage.globalProxyKey,
      settings.password,
    );
    LogService.instance.log(
      'Proxy',
      'GlobalOutboundProxy updated: ${settings.describeForLogs()}',
      level: LogLevel.info,
    );
  }

  /// Reset to default; for tests.
  static void resetForTest() {
    _current = UserProxySettings(type: ProxyType.DEFAULT);
  }

  /// Override in-memory value without touching SharedPreferences; for tests.
  static void setForTest(UserProxySettings settings) {
    _current = settings;
  }
}

/// Decode the proxy stored at [kGlobalOutboundProxyKey]. Falls back to a
/// DEFAULT [UserProxySettings] when the key is missing or malformed.
///
/// Note: this only reads the non-secret fields from SharedPreferences. The
/// password lives in secure storage and is merged in by
/// [GlobalOutboundProxy.initialize].
UserProxySettings readGlobalOutboundProxy(SharedPreferences prefs) {
  final raw = prefs.getString(kGlobalOutboundProxyKey);
  if (raw == null || raw.isEmpty) {
    return UserProxySettings(type: ProxyType.DEFAULT);
  }
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return UserProxySettings.fromJson(decoded);
    }
  } catch (_) {
    // Fall through to default on any decode error.
  }
  return UserProxySettings(type: ProxyType.DEFAULT);
}

/// Persist the non-secret fields of [settings] to [kGlobalOutboundProxyKey].
/// The password component is intentionally stripped — callers who also need
/// to update the password should go through [GlobalOutboundProxy.update].
Future<void> writeGlobalOutboundProxy(
  SharedPreferences prefs,
  UserProxySettings settings,
) async {
  await prefs.setString(
    kGlobalOutboundProxyKey,
    jsonEncode(settings.toJson()),
  );
}
