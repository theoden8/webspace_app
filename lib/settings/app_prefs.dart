import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/settings/pref_read.dart';
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
///
/// Do **not** register state that grants trust on restore. TLS pins
/// (`kTrustedHostsKey`) are the worked example: importing them makes
/// `badCertificateCallback` return true and the webview PROCEED with no
/// prompt, so a backup file would be able to install a
/// man-in-the-middle certificate silently. `TrustedHostsService` persists
/// and reloads that key on its own; it just never rides a backup.
final Map<String, Object> kExportedAppPrefs = <String, Object>{
  'showUrlBar': false,
  'showTabStrip': false,
  // Keep the site tab strip visible in fullscreen (top bar still hidden).
  // Only meaningful when showTabStrip is on.
  'tabStripInFullscreen': false,
  // Show a small floating button that opens the tab strip (and its overflow
  // menu) on demand, in and out of fullscreen. Lets the user reach tabs + menu
  // without pinning the strip. Supersedes the legacy `tabBarButtonInFullscreen`
  // key (still read once on upgrade).
  'tabBarButton': false,
  // Legacy app-wide default corner for the tab-bar button (true = right).
  // The corner is now remembered per site (WebViewModel.tabBarButtonOnRight,
  // set by long-press-dragging the button); this key is only the fallback for
  // sites never dragged. No settings UI writes it anymore — kept registered
  // so pre-per-site backups keep restoring the user's chosen corner.
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
  // Unlocked by tapping the version row in App Settings seven times. Gates
  // affordances that only make sense while diagnosing the app (the Repaint
  // Screen menu entry), so an ordinary user never meets them.
  kDeveloperModeKey: false,
  'linkHandlingEnabled': true,
  // LIR-010 / discussion #439: when the user sends a shared link to an
  // existing site via the dispatch picker, also append exactHost +
  // wildcardSubdomain claims so that domain routes to the site in future.
  // Opt-in (default off): by default a shared link just opens in the chosen
  // site without mutating its claim list — users manage claims manually in
  // the site's link-handling settings.
  'linkHandlingClaimDomains': false,
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
  // Opt-in automatic refresh of the scraped Firefox release version used by
  // generated per-site User-Agents: when true, the app checks Mozilla's
  // published version at startup, at most once a week. Default off — the
  // explicit opt-in keeps the no-unrequested-network contract (DM-004).
  kFirefoxUaAutoRefreshKey: false,
  // Back/forward cache (Android, androidx.webkit BACK_FORWARD_CACHE). A
  // per-WebView WebSettings flag, but the intent is global: instant restore
  // on back/forward navigation. Mirrored into WebViewFactory and applied to
  // every WebView; no-ops where the feature is unsupported.
  kBackForwardCacheEnabledKey: true,
  // NAV-009: what the system back gesture does once a site has no page left
  // to go back to. Off (default) keeps the gesture on webview history only;
  // on, it opens the drawer there and leaves the app on the next press.
  kBackOpensMenuKey: false,
  // HTTPS-005: retry a plain-http main-frame navigation over https, falling
  // back silently when the host does not answer. On by default; chromium does
  // the same for ordinary navigations and Android WebView does not ship it.
  kHttpsUpgradeEnabledKey: true,
  // TOR-003: whether tor also splits circuits by destination address. Per-site
  // isolation is the SOCKS credentials and is never optional; this is the
  // extra split, which gives a site one exit per host it loads from. On by
  // default. Off is for sites that check the client IP across their own hosts,
  // and for anyone who would rather read one address than two.
  kTorIsolateDestAddrKey: false,
};

const String kBackForwardCacheEnabledKey = 'backForwardCacheEnabled';

const String kHttpsUpgradeEnabledKey = 'httpsUpgradeEnabled';
const String kTorIsolateDestAddrKey = 'torIsolateDestAddr';

const String kBackOpensMenuKey = 'backOpensMenu';

const String kFirefoxUaAutoRefreshKey = 'firefoxUaAutoRefresh';

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

/// Write every registered pref from [values] back into [prefs], through
/// [resolveExportedAppPrefs].
Future<void> writeExportedAppPrefs(
  SharedPreferences prefs,
  Map<String, Object?> values,
) async {
  for (final entry in resolveExportedAppPrefs(values).entries) {
    await _writeTypedPref(prefs, entry.key, entry.value);
  }
}

/// The value every registered pref takes when [values] (a backup's
/// `globalPrefs`) is applied. Keys absent from [values] take the registry
/// default; unknown keys are ignored (forward compatibility).
///
/// A value is written under the registry's type, never the file's: storing a
/// String under a key the app reads with `getBool` would throw on every later
/// read. An integral double is accepted for an int key (and an int for a
/// double key); any other mismatch falls back to the default.
Map<String, Object> resolveExportedAppPrefs(Map<String, Object?> values) {
  final result = <String, Object>{};
  for (final entry in kExportedAppPrefs.entries) {
    final key = entry.key;
    var raw = values[key];
    // Superseded by `tabBarButton` in v0.2.7; a backup written by a build in
    // between names only the old key.
    if (raw == null && key == 'tabBarButton') {
      raw = values['tabBarButtonInFullscreen'];
    }
    if (key == kGlobalOutboundProxyKey) raw = _withoutProxyPassword(raw);
    result[key] = _coerceToRegistryType(raw, entry.value) ?? entry.value;
  }
  return result;
}

Object? _coerceToRegistryType(Object? raw, Object defaultValue) {
  if (defaultValue is bool) return raw is bool ? raw : null;
  if (defaultValue is int) {
    if (raw is int) return raw;
    if (raw is double && raw.isFinite && raw == raw.truncateToDouble()) {
      return raw.toInt();
    }
    return null;
  }
  if (defaultValue is double) return raw is num ? raw.toDouble() : null;
  if (defaultValue is String) return raw is String ? raw : null;
  if (defaultValue is List<String>) {
    return raw is List && raw.every((e) => e is String)
        ? List<String>.from(raw)
        : null;
  }
  return null;
}

/// The app-wide proxy rides the registry as a JSON-encoded
/// `UserProxySettings`. v0.2.2 encoded its password too, and
/// `UserProxySettings.fromJson` reads one back, so a password in the file
/// would reach secure storage through `GlobalOutboundProxy.update`. Exports
/// are password-less by contract (PWD-005); drop it. Anything that is not a
/// JSON object passes through: `readGlobalOutboundProxy` reads it as no proxy.
Object? _withoutProxyPassword(Object? raw) {
  if (raw is! String) return raw;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return raw;
  }
  if (decoded is! Map<String, dynamic> || !decoded.containsKey('password')) {
    return raw;
  }
  return jsonEncode(Map<String, dynamic>.from(decoded)..remove('password'));
}

Object? _readTypedPref(SharedPreferences prefs, String key, Object defaultValue) =>
    _coerceToRegistryType(prefs.get(key), defaultValue) ?? defaultValue;

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

/// The isolation preference, for the Tor engine's loader. Defaults to the
/// registry value, so a device that has never seen the setting keeps the
/// stricter behaviour.
Future<bool> readTorIsolateDestAddr() async {
  final prefs = await SharedPreferences.getInstance();
  return readPrefAs<bool>(prefs, kTorIsolateDestAddrKey) ??
      kExportedAppPrefs[kTorIsolateDestAddrKey]! as bool;
}
