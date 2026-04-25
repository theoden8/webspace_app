import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/proxy.dart';

/// Global outbound-proxy settings: applied to every Dart-side HTTP call that
/// is *not* tied to a specific site (DNS blocklist download, ClearURLs rules,
/// content blocker rules, LocalCDN catalog, OSM map tiles in the location
/// picker, …). Per-site outbound calls (favicons, downloads, user-script
/// fetches) use the *site's* proxy, not this one.
///
/// Stored as a JSON-encoded [UserProxySettings] in SharedPreferences. The key
/// is registered in [kExportedAppPrefs] so it round-trips through the
/// settings backup format.
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

  /// Load the persisted value from SharedPreferences. Call once at startup,
  /// after `SharedPreferences.getInstance()` is available.
  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _current = readGlobalOutboundProxy(prefs);
  }

  /// Update both the in-memory cache and the persisted value.
  static Future<void> update(UserProxySettings settings) async {
    _current = settings;
    final prefs = await SharedPreferences.getInstance();
    await writeGlobalOutboundProxy(prefs, settings);
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

/// Persist [settings] to [kGlobalOutboundProxyKey].
Future<void> writeGlobalOutboundProxy(
  SharedPreferences prefs,
  UserProxySettings settings,
) async {
  await prefs.setString(
    kGlobalOutboundProxyKey,
    jsonEncode(settings.toJson()),
  );
}
