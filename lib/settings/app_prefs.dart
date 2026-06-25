import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/trusted_hosts_service.dart';
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
  // Keep the site tab strip visible in fullscreen (top bar still hidden).
  // Only meaningful when showTabStrip is on.
  'tabStripInFullscreen': false,
  // Show a small floating button in fullscreen that opens the tab strip on
  // demand. Only meaningful when showTabStrip is on and tabStripInFullscreen
  // is off (otherwise the strip is always visible).
  'tabBarButtonInFullscreen': false,
  // Which bottom corner the fullscreen tab-bar button sits in (true = right).
  'tabBarButtonOnRight': true,
  // Enter full screen automatically when a site is opened from a home-screen
  // shortcut (Android pinned shortcut / iOS App Intents). On by default: a
  // pinned shortcut is the user's "app launcher" entry point, so the immersive
  // chrome-free view matches the expectation. Per-site `fullscreenMode` still
  // applies independently on every activation.
  'fullscreenOnShortcut': true,
  // Max width (logical px) of each tab in the bottom tab strip. Long site
  // names ellipsize at this width instead of stretching the tab.
  'tabMaxWidth': 140,
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
  // LIR-008: master "Handle shared links" switch. When false, the app
  // ignores incoming share/open intents (Android ACTION_SEND, webspace://,
  // iOS/macOS Share Extension) without crashing. Default: enabled.
  'linkHandlingEnabled': true,
  // LIR-010 / discussion #439: when the user sends a shared link to an
  // existing site via the dispatch picker, also append exactHost +
  // wildcardSubdomain claims so that domain routes to the site in future.
  // Opt-in (default off): by default a shared link just opens in the chosen
  // site without mutating its claim list — users manage claims manually in
  // the site's link-handling settings.
  'linkHandlingClaimDomains': false,
  // User-approved exceptions for self-signed / otherwise-untrusted TLS
  // certificates. Each entry is `host|port|sha256hex` and is consulted by
  // both the webview's `onReceivedServerTrustAuthRequest` and the
  // Dart-side `HttpClient.badCertificateCallback`. Round-trips so a
  // self-hosted user keeps their trust decisions across reinstalls.
  kTrustedHostsKey: <String>[],
  // Gates uBO web_accessible_resources/ — the resource pool that
  // backs $redirect= rules (noop.js, 1x1.gif, neutered tracker stubs)
  // and snippet injection. Enabled by default: filter authors rely on
  // $redirect= for replacing real tracker scripts with stubs that
  // satisfy the page's expected API surface without sending data home.
  // Turn off to make $redirect= drop the request instead — see
  // openspec/specs/content-blocker/spec.md CB-013.
  'useUboResources': true,
  // User-chosen UI language as a locale tag (e.g. 'de', 'pt_BR', 'zh_Hant').
  // Empty string means follow the system locale. Applied to MaterialApp.locale.
  'appLocaleOverride': '',
  // Back/forward cache (Android, androidx.webkit BACK_FORWARD_CACHE). A
  // per-WebView WebSettings flag, but the intent is global: instant restore
  // on back/forward navigation. Mirrored into WebViewFactory and applied to
  // every WebView; no-ops where the feature is unsupported.
  kBackForwardCacheEnabledKey: true,
};

const String kBackForwardCacheEnabledKey = 'backForwardCacheEnabled';

const String kLinkHandlingEnabledKey = 'linkHandlingEnabled';
const String kLinkHandlingClaimDomainsKey = 'linkHandlingClaimDomains';
const String kUseUboResourcesKey = 'useUboResources';
const String kAppLocaleOverrideKey = 'appLocaleOverride';

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
