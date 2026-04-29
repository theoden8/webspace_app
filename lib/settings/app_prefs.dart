import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/global_outbound_proxy.dart';

/// Registry of global app-level preferences that are round-tripped through
/// settings export/import.
///
/// **To add a new global UI setting so it survives export/import:**
///   1. Add its SharedPreferences key and default value here.
///   2. Nothing else — the backup service reads/writes every registered key,
///      and the integrity test in `test/settings_backup_test.dart`
///      automatically exercises every entry.
///
/// Only include user-facing preferences (theme toggles, UI visibility flags,
/// etc.). Do **not** add migration flags, download timestamps, cache indices,
/// or any pref that ties to downloaded blob data (DNS blocklist, content
/// blocker, localcdn) — those are machine state, not user intent.
///
/// Per-site settings (javascriptEnabled, userAgent, proxy, ...) live on
/// `WebViewModel` and are exported via the `sites` array; they do not belong
/// here.
final Map<String, Object> kExportedAppPrefs = <String, Object>{
  'showUrlBar': false,
  'showTabStrip': false,
  'showStatsBanner': true,
  // Tile URL used by the optional location picker map. Only queried after
  // the user explicitly taps "Load map" on the picker — no requests happen
  // from normal app use.
  'osmTileUrl': 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  // App-global outbound proxy applied to every Dart-side HTTP call that is
  // not tied to a specific site (DNS blocklist, ClearURLs, content blocker,
  // LocalCDN, OSM tiles, etc.). Per-site DEFAULT also resolves through this
  // value via `resolveEffectiveProxy`. Stored as a JSON-encoded
  // UserProxySettings; round-trips through backup/restore as a String.
  kGlobalOutboundProxyKey: kGlobalOutboundProxyDefault,
};

/// Read every registered pref from [prefs] into a map suitable for embedding
/// in a `SettingsBackup`. Missing keys fall back to their registry default.
Map<String, Object?> readExportedAppPrefs(SharedPreferences prefs) {
  final result = <String, Object?>{};
  for (final entry in kExportedAppPrefs.entries) {
    final key = entry.key;
    final defaultValue = entry.value;
    result[key] = _readTypedPref(prefs, key, defaultValue);
  }
  return result;
}

/// Write every registered pref from [values] back into [prefs]. Keys absent
/// from [values] fall back to the registry default; unknown keys in [values]
/// are ignored (forward compatibility).
Future<void> writeExportedAppPrefs(
  SharedPreferences prefs,
  Map<String, Object?> values,
) async {
  for (final entry in kExportedAppPrefs.entries) {
    final key = entry.key;
    final defaultValue = entry.value;
    final raw = values.containsKey(key) ? values[key] : defaultValue;
    await _writeTypedPref(prefs, key, raw ?? defaultValue);
  }
}

Object? _readTypedPref(SharedPreferences prefs, String key, Object defaultValue) {
  if (defaultValue is bool) {
    return prefs.getBool(key) ?? defaultValue;
  }
  if (defaultValue is int) {
    return prefs.getInt(key) ?? defaultValue;
  }
  if (defaultValue is double) {
    return prefs.getDouble(key) ?? defaultValue;
  }
  if (defaultValue is String) {
    return prefs.getString(key) ?? defaultValue;
  }
  if (defaultValue is List<String>) {
    return prefs.getStringList(key) ?? defaultValue;
  }
  throw UnsupportedError(
    'Unsupported pref type ${defaultValue.runtimeType} for key $key',
  );
}

Future<void> _writeTypedPref(
  SharedPreferences prefs,
  String key,
  Object value,
) async {
  if (value is bool) {
    await prefs.setBool(key, value);
  } else if (value is int) {
    await prefs.setInt(key, value);
  } else if (value is double) {
    await prefs.setDouble(key, value);
  } else if (value is String) {
    await prefs.setString(key, value);
  } else if (value is List) {
    await prefs.setStringList(key, value.map((e) => e.toString()).toList());
  } else {
    throw UnsupportedError(
      'Unsupported pref type ${value.runtimeType} for key $key',
    );
  }
}
