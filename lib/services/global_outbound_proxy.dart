import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/proxy.dart';

/// Global outbound-proxy settings: applied to every Dart-side HTTP call that
/// is *not* tied to a specific site (DNS blocklist download, ClearURLs rules,
/// content blocker rules, LocalCDN catalog, OSM map tiles in the location
/// picker, …). Per-site outbound calls (favicons, downloads, user-script
/// fetches) use the *site's* proxy, not this one.
///
/// Stored under [AppPref.globalOutboundProxy] as a JSON-encoded
/// [UserProxySettings] (the non-secret fields only), so they round-trip
/// through the settings backup format. The password lives in
/// `flutter_secure_storage` via [ProxyPasswordSecureStorage], keyed by
/// [ProxyPasswordSecureStorage.globalProxyKey], and is hydrated into the
/// in-memory [_current] at app startup; it is intentionally NOT included in
/// the export (PWD-005) — same contract as `isSecure=true` cookies, see
/// `openspec/specs/proxy-password-secure-storage/spec.md`.
///
/// In-memory cache of the global outbound proxy. Initialized by
/// [GlobalOutboundProxy.initialize] at app startup so synchronous callers
/// (e.g. flutter_map's tile provider) don't have to await SharedPreferences.
class GlobalOutboundProxy {
  GlobalOutboundProxy._();

  static UserProxySettings _current = UserProxySettings(type: ProxyType.DEFAULT);

  static UserProxySettings get current => _current;

  /// Secure-storage handle for the password component. Tests may override.
  static ProxyPasswordSecureStorage _passwordStore =
      ProxyPasswordSecureStorage();

  static void setPasswordStoreForTest(ProxyPasswordSecureStorage store) {
    _passwordStore = store;
  }

  /// Load the persisted value from SharedPreferences. Call once at startup,
  /// after `SharedPreferences.getInstance()` is available.
  ///
  /// Performs a one-shot migration of any legacy plaintext password found
  /// under [AppPref.globalOutboundProxy] into secure storage.
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    await _passwordStore.migrateLegacyPassword(
      prefs: prefs,
      prefsKey: AppPref.globalOutboundProxy.key,
      secureKey: ProxyPasswordSecureStorage.globalProxyKey,
    );
    _current = readGlobalOutboundProxy(prefs);
    final pwd = await _passwordStore
        .loadPassword(ProxyPasswordSecureStorage.globalProxyKey);
    if (pwd != null && pwd.isNotEmpty) {
      _current.password = pwd;
    }
    LogTag.proxy.info(
        'GlobalOutboundProxy initialized: ${_current.describeForLogs()}',
        sensitive: true);
  }

  /// Update both the in-memory cache and the persisted value.
  static Future<void> update(UserProxySettings settings) async {
    _current = settings;
    // toJson carries no password: that goes to secure storage below.
    await AppPref.globalOutboundProxy.set(jsonEncode(settings.toJson()));
    await _passwordStore.savePassword(
      ProxyPasswordSecureStorage.globalProxyKey,
      settings.password,
    );
    LogTag.proxy.info(
        'GlobalOutboundProxy updated: ${settings.describeForLogs()}',
        sensitive: true);
  }

  static void resetForTest() {
    _current = UserProxySettings(type: ProxyType.DEFAULT);
  }

  /// Override in-memory value without touching SharedPreferences; for tests.
  static void setForTest(UserProxySettings settings) {
    _current = settings;
  }
}

/// Decode the proxy stored at [AppPref.globalOutboundProxy]. Falls back to a
/// DEFAULT [UserProxySettings] when the key is missing or malformed.
///
/// Note: this only reads the non-secret fields from SharedPreferences. The
/// password lives in secure storage and is merged in by
/// [GlobalOutboundProxy.initialize].
UserProxySettings readGlobalOutboundProxy(SharedPreferences prefs) {
  final raw = AppPref.globalOutboundProxy.stored(prefs);
  if (raw.isEmpty) return UserProxySettings(type: ProxyType.DEFAULT);
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return UserProxySettings.fromJson(decoded);
    }
  } on FormatException {
    // Fall through to the default.
  }
  return UserProxySettings(type: ProxyType.DEFAULT);
}
