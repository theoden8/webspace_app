import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/settings/demo_mode.dart';

/// A global app-level preference: its SharedPreferences key, its default,
/// and the value the app runs with. Every entry rides settings
/// export/import, in declaration order.
///
/// Only include user-facing preferences. Do **not** add migration flags,
/// download timestamps, cache indices, or any pref that ties to downloaded
/// blob data (DNS blocklist, content blocker, localcdn): those are machine
/// state, not user intent. Per-site settings live on `WebViewModel` and ride
/// the `sites` array.
///
/// Do **not** register state that grants trust on restore. TLS pins
/// (`kTrustedHostsKey`) are the worked example: importing them makes
/// `badCertificateCallback` return true and the webview PROCEED with no
/// prompt, so a backup file would be able to install a man-in-the-middle
/// certificate silently. `TrustedHostsService` persists and reloads that key
/// on its own; it just never rides a backup.
enum AppPref<T extends Object> {
  showUrlBar('showUrlBar', fallback: false),
  tabsEnabled('tabsEnabled', fallback: true),
  externalLinkMode('externalLinkMode', fallback: 'inApp'),
  routeOutboundLinks('routeOutboundLinks', fallback: false),
  // NESTED-014: a sign-in window a tap opened shows as a real popup, where
  // the host offers it (`PopupKind.signInOffered`); a site may keep its own.
  signInPopups('signInPopups', fallback: true),
  showTabStrip('showTabStrip', fallback: false),
  // Keep the site tab strip visible in fullscreen (top bar still hidden).
  // Only meaningful when showTabStrip is on.
  tabStripInFullscreen('tabStripInFullscreen', fallback: false),
  // FS-012: the edge the tab strip runs along, 'top' or 'bottom'; empty
  // follows the platform, so a backup carries only a choice the user made.
  tabStripEdge('tabStripEdge', fallback: ''),
  // Floating button that opens the tab strip (and its overflow menu) on
  // demand. Superseded `tabBarButtonInFullscreen` in v0.2.7; a device or a
  // backup from a build in between names only the old key.
  tabBarButton('tabBarButton', fallback: false, legacyKey: 'tabBarButtonInFullscreen'),
  // Legacy app-wide default corner for the tab-bar button (true = right).
  // The corner is now remembered per site (WebViewModel.tabBarButtonCorner);
  // this is only the fallback for sites never dragged. No settings UI writes
  // it; kept so pre-per-site backups keep restoring the user's corner.
  tabBarButtonOnRight('tabBarButtonOnRight', fallback: true),
  // On by default: a pinned shortcut is the user's "app launcher" entry
  // point, so the chrome-free view matches the expectation. Per-site
  // `fullscreenMode` still applies independently on every activation.
  fullscreenOnShortcut('fullscreenOnShortcut', fallback: true),
  // Max width (logical px) of each tab in the tab strip.
  tabMaxWidth('tabMaxWidth', fallback: 140),
  showStatsBanner('showStatsBanner', fallback: true),
  // Tile server for the location picker map. Only queried after the user
  // taps "Load map" on the picker.
  osmTileUrl('osmTileUrl', fallback: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png'),
  // The app-wide outbound proxy, JSON of the non-secret fields of a
  // UserProxySettings; the default is a DEFAULT-type one. Every Dart-side
  // call not tied to a site goes through it, and so does a site on DEFAULT
  // (`resolveEffectiveProxy`).
  globalOutboundProxy(
      'globalOutboundProxy', fallback: '{"type":0,"address":null,"username":null}'),
  // PROXY-030: the proxy library (gateways, credentials, saved proxies), as
  // JSON of the non-secret fields. Passwords stay in secure storage and never
  // ride a backup (PWD-005, PWD-007).
  proxyLibrary('proxyLibrary', fallback: '{}'),
  // Unlocked by tapping the version row seven times. Gates affordances that
  // only make sense while diagnosing the app.
  developerMode('developerMode', fallback: false),
  // PROXY-013: the per-site proxy router, where the WebView can run it. The
  // key keeps the name it shipped under as an Experimental switch, so a user
  // who turned it off there keeps it off.
  proxyRouter('experimentalProxyRouter', fallback: true),
  // DEVTOOLS-011: the Experimental switches, each new when it was added, so
  // off.
  experimentalTextureRendering('experimentalTextureRendering', fallback: false),
  experimentalFolderLibrary('experimentalFolderLibrary', fallback: false),
  experimentalSignInPopups('experimentalSignInPopups', fallback: false),
  experimentalWebExtensions('experimentalWebExtensions', fallback: false),
  // WEBEXT-018: the daily check of each extension's source. Off: no request
  // reaches a source the user did not ask to check.
  webExtensionsCheckUpdates('webExtensionsCheckUpdates', fallback: false),
  // WEBEXT-019: offered only in a build from outside the App Store.
  webExtensionsAutoUpdate('webExtensionsAutoUpdate', fallback: false),
  experimentalDesktopTray('experimentalDesktopTray', fallback: false),
  // TOR-025: Tor sites through a tor already running on the device. The key
  // keeps the name it shipped under as an Experimental switch.
  externalTor('experimentalExternalTor', fallback: false),
  // TOR-025: the external tor's SOCKS address; Orbot's and the system tor
  // service's SocksPort.
  externalTorAddress('externalTorAddress', fallback: '127.0.0.1:9050'),
  // TOR-026: the external tor's control port, a socket path or host:port;
  // empty for none. Its password is a secret and lives in the keystore.
  externalTorControl('externalTorControl', fallback: ''),
  // LIR-008: master "Handle shared links" switch. When off, incoming share
  // and open intents are dropped.
  linkHandlingEnabled('linkHandlingEnabled', fallback: true),
  // LIR-010: a shared link sent to a site through the picker also claims
  // its domain for that site. Opt-in: by default the link just opens there.
  linkHandlingClaimDomains('linkHandlingClaimDomains', fallback: false),
  // LIR-029: the siteId Web search starts with when the site on screen
  // names none. Empty until the user picks one, so no build ships a default
  // engine. Never an archived site's id (ARCH-001).
  webSearchDefaultSite('webSearchDefaultSite', fallback: ''),
  // CB-013: uBO web_accessible_resources, which back $redirect= rules with
  // stubs that satisfy the page's expected API. Off makes $redirect= drop
  // the request instead, which breaks some sites.
  useUboResources('useUboResources', fallback: true),
  // UI language as a locale tag ('de', 'pt_BR', 'zh_Hant'); empty follows
  // the system locale.
  appLocaleOverride('appLocaleOverride', fallback: ''),
  // DM-004: weekly check of Mozilla's published Firefox version for
  // generated User-Agents. Off: no network the user did not ask for.
  firefoxUaAutoRefresh('firefoxUaAutoRefresh', fallback: false),
  // androidx.webkit BACK_FORWARD_CACHE, applied to every WebView; a no-op
  // where unsupported.
  backForwardCacheEnabled('backForwardCacheEnabled', fallback: true),
  // NAV-009: what the back gesture does once a site has no page left to go
  // back to. Off keeps it on webview history; on opens the drawer there and
  // leaves the app on the next press.
  backOpensMenu('backOpensMenu', fallback: false),
  // HTTPS-005: retry a plain-http main-frame navigation over https, falling
  // back silently. On: chromium does the same and Android WebView does not.
  httpsUpgradeEnabled('httpsUpgradeEnabled', fallback: true),
  // SCREENBLOCK-002: withhold the whole app from screenshots, recordings
  // and the recent-apps preview. Android only.
  blockScreenshots('blockScreenshots', fallback: false),
  // WEBSPACE-015: how the library's folders lay out their sites, every folder
  // at once, and apart from them how its home lays out the webspaces: a
  // LibraryLayout's name.
  libraryLayout('libraryLayout', fallback: 'auto'),
  libraryWebspaceLayout('libraryWebspaceLayout', fallback: 'auto'),
  // WEBSPACE-017: every icon in the library at once, as a percentage of its
  // own size.
  libraryIconSize('libraryIconSize', fallback: 100),
  // NOTIF-018: closing the desktop window hides it and the app keeps running,
  // so its sites can still notify. Linux and macOS only.
  keepRunningWhenClosed('keepRunningWhenClosed', fallback: false),
  // SUGGEST-011: keep the popular sites' filter lists between downloads, so
  // a refresh within a month fetches only the top rows: storage for
  // bandwidth. Off: nothing is kept but the rows.
  topSitesKeepFilters('topSitesKeepFilters', fallback: false),
  // SUGGEST-012: the add-site screen offers the popular sites list until it
  // is downloaded or this offer is dismissed.
  topSitesOffer('topSitesOffer', fallback: true);

  const AppPref(this.key, {required this.fallback,this.legacyKey})
      : assert(fallback is bool || fallback is int || fallback is String);

  final String key;
  final T fallback;

  /// A key an older build stored this pref under, read when [key] is absent.
  final String? legacyKey;

  static final List<ValueNotifier<Object>> _live = [
    for (final pref in values) pref._newNotifier(),
  ];

  ValueNotifier<T> _newNotifier() => ValueNotifier<T>(fallback);

  ValueNotifier<T> get _notifier => _live[index] as ValueNotifier<T>;

  /// What the app runs with: the stored value once [load]ed, else
  /// [fallback].
  T get value => _notifier.value;

  ValueListenable<T> get listenable => _notifier;

  /// Fires when any pref's [value] changes.
  static final Listenable anyChange = Listenable.merge(_live);

  /// Applies [next] now and persists it, except in demo mode, which never
  /// writes.
  Future<void> set(T next) async {
    _notifier.value = next;
    if (isDemoMode) return;
    await _write(await SharedPreferences.getInstance(), next: next);
  }

  /// The stored value. A value of another type reads as absent: from
  /// v0.2.2 through v0.3.1 an import stored each `globalPrefs` value under
  /// the file's JSON type, and a typed getter throws on that.
  T stored(SharedPreferences prefs) =>
      _coerce(prefs.get(key)) ??
      (legacyKey == null ? null : _coerce(prefs.get(legacyKey!))) ??
      fallback;

  T load(SharedPreferences prefs) => _notifier.value = stored(prefs);

  static void loadAll(SharedPreferences prefs) {
    for (final pref in values) {
      pref.load(prefs);
    }
  }

  /// Test seam: sets [value] without persisting it.
  set debugValue(T next) => _notifier.value = next;

  /// The value a backup's `globalPrefs` gives this pref, under this pref's
  /// type, never the file's: an integral double is accepted for an int, any
  /// other mismatch takes [fallback].
  T fromBackup(Map<String, Object?> globalPrefs) {
    var raw = globalPrefs[key] ?? globalPrefs[legacyKey];
    if (this == globalOutboundProxy) raw = _withoutProxyPassword(raw);
    return _coerce(raw) ?? fallback;
  }

  Future<void> _restore(
    SharedPreferences prefs, {
    required Map<String, Object?> globalPrefs,
  }) async {
    final next = fromBackup(globalPrefs);
    await _write(prefs, next: next);
    _notifier.value = next;
  }

  T? _coerce(Object? raw) => switch (raw) {
        T value => value,
        double d when fallback is int && d.isFinite && d == d.truncateToDouble() =>
          d.toInt() as T,
        _ => null,
      };

  Future<void> _write(SharedPreferences prefs, {required T next}) =>
      switch (next) {
        bool v => prefs.setBool(key, v),
        int v => prefs.setInt(key, v),
        String v => prefs.setString(key, v),
        _ => throw UnsupportedError('$key: ${next.runtimeType}'),
      };
}

/// Every pref as stored in [prefs], for a backup's `globalPrefs`.
Map<String, Object?> readExportedAppPrefs(SharedPreferences prefs) => {
      for (final pref in AppPref.values) pref.key: pref.stored(prefs),
    };

/// Applies a backup's `globalPrefs` to [prefs] and to the running app. Keys
/// absent from [values] take their default; unknown keys are ignored
/// (forward compatibility).
Future<void> writeExportedAppPrefs(
  SharedPreferences prefs, {
  required Map<String, Object?> values,
}) async {
  for (final pref in AppPref.values) {
    await pref._restore(prefs, globalPrefs: values);
  }
}

/// What [writeExportedAppPrefs] would apply, keyed like `globalPrefs`.
Map<String, Object> resolveExportedAppPrefs(Map<String, Object?> values) => {
      for (final pref in AppPref.values) pref.key: pref.fromBackup(values),
    };

/// v0.2.2 encoded the app-wide proxy's password too, and
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
