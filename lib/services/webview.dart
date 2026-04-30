import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/current_location_service.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/download_engine.dart';
import 'package:webspace/services/download_manager.dart';
import 'package:webspace/services/download_url_revert_engine.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/ios_universal_link_bypass.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/location.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/widgets/root_messenger.dart';

// Re-export inapp.Cookie as Cookie for convenience
typedef Cookie = inapp.Cookie;

/// Translate WebSpace's [UserProxySettings] into the fork's
/// [`inapp.ProxySettings`] type, which the fork's
/// `preWKWebViewConfiguration` reads and applies to the per-WebView
/// `WKWebsiteDataStore.proxyConfigurations` (iOS 17+ / macOS 14+ only).
/// Returns null for `ProxyType.DEFAULT` or invalid configs so the
/// native side leaves any previously-set proxy in place; callers that
/// need to *clear* a proxy should pass an empty `ProxySettings`.
///
/// Credentials, when present, are embedded in the proxy URL
/// (`scheme://user:pass@host:port`). Apple's
/// `WKWebsiteDataStore.proxyConfigurations` does not expose a separate
/// auth API in the public surface; the URL-embedded form is what the
/// underlying `Network.framework` honors when the proxy server
/// challenges with `407 Proxy Authentication Required`.
inapp.ProxySettings? _userProxyToInappProxy(UserProxySettings settings) {
  if (settings.type == ProxyType.DEFAULT) return null;
  final address = settings.address;
  if (address == null || address.isEmpty) return null;
  final parts = address.split(':');
  if (parts.length != 2) return null;
  final host = parts[0];
  final port = int.tryParse(parts[1]);
  if (host.isEmpty || port == null || port <= 0 || port > 65535) return null;
  final scheme = switch (settings.type) {
    ProxyType.HTTPS => 'https',
    ProxyType.SOCKS5 => 'socks5',
    _ => 'http',
  };
  final auth = settings.hasCredentials
      ? '${Uri.encodeComponent(settings.username!)}:'
          '${Uri.encodeComponent(settings.password!)}@'
      : '';
  return inapp.ProxySettings(
    proxyRules: [inapp.ProxyRule(url: '$scheme://$auth$host:$port')],
  );
}

/// Extension to add JSON serialization to inapp.Cookie
extension CookieJson on inapp.Cookie {
  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'expiresDate': expiresDate,
    'isSecure': isSecure,
    'isHttpOnly': isHttpOnly,
    'isSessionOnly': isSessionOnly,
    'sameSite': sameSite?.toString(),
  };
}

/// Factory function to create Cookie from JSON
Cookie cookieFromJson(Map<String, dynamic> json) => inapp.Cookie(
  name: json['name'],
  value: json['value'],
  domain: json['domain'],
  path: json['path'],
  expiresDate: json['expiresDate'],
  isSecure: json['isSecure'],
  isHttpOnly: json['isHttpOnly'],
  isSessionOnly: json['isSessionOnly'],
  sameSite: json['sameSite'] != null
      ? inapp.HTTPCookieSameSitePolicy.values.firstWhere(
          (e) => e.toString() == json['sameSite'],
          orElse: () => inapp.HTTPCookieSameSitePolicy.LAX,
        )
      : null,
);

/// Cookie manager - thin wrapper around inapp.CookieManager
class CookieManager {
  final _manager = inapp.CookieManager.instance();

  Future<List<Cookie>> getCookies({required Uri url}) async =>
      _manager.getCookies(url: inapp.WebUri(url.toString()));

  /// Returns every cookie in the native jar regardless of URL scoping.
  /// `getCookies(url)` only returns cookies that would be sent with a request
  /// to that URL, which misses cookies scoped to sibling subdomains (e.g.
  /// `accounts.google.com` when querying with `mail.google.com`).
  ///
  /// Platform support for the underlying `WKHTTPCookieStore.getAllCookies()`
  /// is iOS/macOS only — Android's `CookieManager` has no "get all" endpoint.
  /// On Android, callers MUST pass [candidateUrls] (typically every loaded
  /// site's `initUrl` and `currentUrl`); the result is aggregated via
  /// per-URL `getCookies`, deduplicated by `(name, domain, path)`. This is
  /// a best-effort capture — cookies on subdomains of a candidate URL that
  /// aren't reachable from it (e.g. `accounts.google.com` when only
  /// `mail.google.com` has been visited) cannot be discovered on Android.
  Future<List<Cookie>> getAllCookies({List<Uri>? candidateUrls}) async {
    if (Platform.isIOS || Platform.isMacOS) {
      return _manager.getAllCookies();
    }
    if (candidateUrls == null || candidateUrls.isEmpty) return [];
    final seen = <String>{};
    final out = <Cookie>[];
    for (final url in candidateUrls) {
      final cookies = await getCookies(url: url);
      for (final c in cookies) {
        final key = '${c.name}|${c.domain ?? ''}|${c.path ?? ''}';
        if (seen.add(key)) out.add(c);
      }
    }
    return out;
  }

  Future<void> setCookie({
    required Uri url,
    required String name,
    required String value,
    String? domain,
    String? path,
    int? expiresDate,
    bool? isSecure,
    bool? isHttpOnly,
  }) async {
    if (value.isEmpty) return;
    await _manager.setCookie(
      url: inapp.WebUri(url.toString()),
      name: name,
      value: value,
      domain: domain,
      path: path ?? '/',
      expiresDate: expiresDate,
      isSecure: isSecure,
      isHttpOnly: isHttpOnly,
    );
  }

  Future<void> deleteCookie({
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) => _manager.deleteCookie(
    url: inapp.WebUri(url.toString()),
    name: name,
    domain: domain,
    path: path ?? '/',
  );

  /// Delete all cookies for a URL.
  /// Used for per-site cookie isolation when switching between same-domain sites.
  Future<void> deleteAllCookiesForUrl(Uri url) async {
    final cookies = await getCookies(url: url);
    for (final cookie in cookies) {
      await deleteCookie(
        url: url,
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path,
      );
    }
  }

  /// Delete ALL cookies from all domains.
  /// Used for aggressive cookie isolation when switching between same-domain sites.
  Future<void> deleteAllCookies() async {
    await _manager.deleteAllCookies();
  }
}

/// Find matches result
class FindMatchesResult {
  int activeMatchOrdinal = 0;
  int numberOfMatches = 0;
}

/// Theme preference for webviews
enum WebViewTheme { light, dark, system }

/// Proxy manager singleton.
///
/// Two delivery paths coexist behind a single API:
///
///   * **Android.** Routes through `inapp.ProxyController` — a process-wide
///     singleton override (`PROXY_OVERRIDE` WebViewFeature). Per-site config
///     in the data model is fictional under container mode: with multiple
///     same-base-domain sites loaded concurrently, the last applied proxy
///     wins for every WebView. See PROXY-008.
///   * **iOS 17+ / macOS 14+.** Genuine per-site proxy via
///     `WKWebsiteDataStore.proxyConfigurations` on the per-container data
///     store, created by the WebSpace fork's `preWKWebViewConfiguration`
///     hook. The proxy ships with [`inapp.InAppWebViewSettings.proxySettings`]
///     at WebView construction; this class is a no-op on those platforms.
class ProxyManager {
  static final ProxyManager _instance = ProxyManager._internal();
  factory ProxyManager() => _instance;
  ProxyManager._internal();

  Future<void> setProxySettings(UserProxySettings settings) async {
    if (!PlatformInfo.isProxySupported) return;

    // iOS / macOS: proxy travels through the fork's
    // `inapp.InAppWebViewSettings.proxySettings` field at WebView
    // construction. Nothing to do at the global ProxyController level —
    // `inapp.ProxyController` is Android-only. Runtime updates of the
    // per-site proxy require the WebView to be rebuilt by the caller (see
    // [WebViewModel.updateProxySettings]).
    if (Platform.isIOS || Platform.isMacOS) return;

    final controller = inapp.ProxyController.instance();

    // When the per-site setting is DEFAULT, fall through to the app-global
    // outbound proxy. This keeps webview traffic and Dart-side traffic
    // honoring the same proxy precedence: explicit per-site override wins,
    // otherwise the global applies, otherwise system/direct.
    final effective = resolveEffectiveProxy(settings);

    if (effective.type == ProxyType.DEFAULT) {
      await controller.clearProxyOverride();
      return;
    }

    if (effective.address == null || effective.address!.isEmpty) {
      throw Exception('Proxy address is required');
    }

    final parts = effective.address!.split(':');
    if (parts.length != 2) {
      throw Exception('Proxy address must be in format host:port');
    }

    final host = parts[0];
    final port = int.tryParse(parts[1]);
    if (port == null) {
      throw Exception('Invalid port number');
    }

    final scheme = switch (effective.type) {
      ProxyType.HTTPS => 'https',
      ProxyType.SOCKS5 => 'socks5',
      _ => 'http',
    };

    final proxyUrl = effective.hasCredentials
        ? '$scheme://${Uri.encodeComponent(effective.username!)}:${Uri.encodeComponent(effective.password!)}@$host:$port'
        : '$scheme://$host:$port';

    await controller.setProxyOverride(
      settings: inapp.ProxySettings(
        proxyRules: [inapp.ProxyRule(url: proxyUrl)],
        bypassRules: ['<local>'],
      ),
    );
  }

  Future<void> clearProxy() async {
    if (!PlatformInfo.isProxySupported) return;
    if (Platform.isIOS || Platform.isMacOS) return;
    await inapp.ProxyController.instance().clearProxyOverride();
  }
}

/// Platform info - proxy support detection.
///
/// Returns true on:
/// - Android, when the System WebView reports `PROXY_OVERRIDE` support.
/// - iOS / macOS, unconditionally — the fork's
///   `preWKWebViewConfiguration` gates internally on iOS 17+ / macOS 14+.
///   Below that floor, the per-site proxy block silently no-ops and the
///   site uses system default routing (matches `ProxyType.DEFAULT`).
/// - Linux, unconditionally — the fork's `flutter_inappwebview_linux`
///   ProxyManager calls `webkit_network_session_set_proxy_settings` on
///   the active session. WebKitGTK / WPE has shipped the proxy API
///   since 2.26; the fork builds against ≥ 2.40 (matching our pubspec
///   override floor) so no runtime feature probe is needed.
class PlatformInfo {
  static bool? _isProxySupportedCached;

  static Future<void> initialize() async {
    if (Platform.isIOS || Platform.isMacOS || Platform.isLinux) {
      // iOS / macOS: native side gates per-version
      // (`#available(iOS 17.0, macOS 14.0, *)`); surface the toggle
      // unconditionally and let the per-site proxy block silently
      // no-op on older OS releases.
      // Linux: the fork's ProxyController binds via
      // `webkit_network_session_set_proxy_settings`, available on
      // every WebKitGTK / WPE build we support.
      _isProxySupportedCached = true;
      return;
    }
    try {
      _isProxySupportedCached = await inapp.WebViewFeature.isFeatureSupported(
        inapp.WebViewFeature.PROXY_OVERRIDE,
      );
    } catch (e) {
      _isProxySupportedCached = false;
    }
  }

  static bool get isProxySupported => _isProxySupportedCached ?? false;
}

/// Configuration for creating a webview
class WebViewConfig {
  /// Unique key to force widget recreation when settings change.
  /// When this key changes, Flutter will create a new widget state.
  final Key? key;
  /// Site ID for per-site DNS statistics tracking.
  final String? siteId;
  final String initialUrl;
  final bool javascriptEnabled;
  final String? userAgent;
  final bool thirdPartyCookiesEnabled;
  final bool incognito;
  /// Language code for Accept-Language header (e.g., 'en', 'es', 'fr').
  /// If null, uses system default.
  final String? language;
  final Function(String url)? onUrlChanged;
  final Function(List<Cookie> cookies)? onCookiesChanged;
  /// Cookie reader used inside [_onLoadStop] before invoking
  /// [onCookiesChanged]. Exactly one of these is non-null per
  /// `_WebSpacePageState`'s `_useContainers` decision: legacy mode
  /// passes [cookieManager] (global default jar); container mode
  /// passes [containerCookieManager] (the fork's plugin routes through
  /// the bound container via `webViewController:`).
  final CookieManager? cookieManager;
  final ContainerCookieManager? containerCookieManager;
  /// siteId of the owning [WebViewModel]. Required when
  /// [containerCookieManager] is set so per-site reads route through
  /// the bound WebView's container.
  final String? cookieSiteId;
  final Function(int activeMatch, int totalMatches)? onFindResult;
  final Function(String url, bool hasGesture)? shouldOverrideUrlLoading;
  /// Fires when the page enters or exits a loading state. Driven by
  /// `onLoadStart` (true) and `onLoadStop` (false). The call site can
  /// use this to swap a Refresh button with a Stop button while a
  /// navigation is in flight.
  final Function(bool isLoading)? onLoadingChanged;
  /// Callback for when a popup window is requested (e.g., Cloudflare challenges).
  /// Returns a widget (typically a WebView) to display in the popup.
  /// The callback receives the windowId for the popup and the requested URL.
  final Future<void> Function(int windowId, String url)? onWindowRequested;
  /// Callback when page HTML should be cached. Called on page load with (url, html).
  final Function(String url, String html)? onHtmlLoaded;
  /// Optional pre-gate for the [onHtmlLoaded] path. Returning `false`
  /// makes `onLoadStop` skip the `controller.getHtml()` IPC entirely
  /// (not just the encrypt+write that follows). The IPC is the
  /// expensive, lifecycle-racing piece — the renderer has to walk and
  /// serialize the live DOM, and during a frame teardown that walk
  /// can hold a `raw_ptr` to a soon-to-be-freed Frame. Skipping the
  /// IPC outright is the only way to drop the renderer pressure.
  /// When unset, every `onLoadStop` fetches HTML (legacy behavior).
  final bool Function()? shouldFetchHtml;
  /// Optional cached HTML to display when offline. Sub-resources (CSS/JS/images)
  /// load from the browser's HTTP cache via LOAD_CACHE_ELSE_NETWORK mode.
  final String? initialHtml;
  /// Whether to strip tracking parameters from URLs via ClearURLs rules.
  final bool clearUrlEnabled;
  /// Whether to block navigation to domains on the Hagezi DNS blocklist.
  final bool dnsBlockEnabled;
  /// Whether to apply ABP content blocker rules (ads, trackers, cosmetic).
  final bool contentBlockEnabled;
  /// Whether to serve CDN resources from local cache (Android only).
  final bool localCdnEnabled;
  /// Callback for JS console messages.
  final Function(String message, inapp.ConsoleMessageLevel level)? onConsoleMessage;
  /// Per-site user scripts to inject into the webview.
  final List<UserScriptConfig> userScripts;
  /// Callback to confirm fetching a script from a non-whitelisted URL.
  /// Returns true if the user approves, false to block.
  final Future<bool> Function(String url)? onConfirmScriptFetch;
  /// Callback fired when the webview tries to navigate to a non-webview
  /// URL (`intent://`, `tel:`, `mailto:`, custom app schemes). The
  /// webview always cancels such navigations; the host UI decides
  /// whether to launch the target app after confirming with the user.
  final Future<void> Function(String url, ExternalUrlInfo info)? onExternalSchemeUrl;
  /// Optional pull-to-refresh controller for enabling pull-to-refresh gesture.
  final inapp.PullToRefreshController? pullToRefreshController;
  /// Per-site geolocation mode. [LocationMode.spoof] injects a shim that
  /// overrides `navigator.geolocation` with [spoofLatitude]/[spoofLongitude].
  final LocationMode locationMode;
  final double? spoofLatitude;
  final double? spoofLongitude;
  final double spoofAccuracy;
  /// IANA timezone name reported via [Intl.DateTimeFormat] and
  /// [Date.prototype.getTimezoneOffset]. Null leaves the real zone.
  final String? spoofTimezone;
  /// When true, the effective spoof timezone is derived from
  /// (spoofLatitude, spoofLongitude) at shim build time using
  /// [TimezoneLocationService]. Mutually exclusive with [spoofTimezone];
  /// if the polygon dataset is absent or the lookup misses, this falls
  /// through to no-timezone-spoof.
  final bool spoofTimezoneFromLocation;
  /// WebRTC policy — prevents real-IP leak that bypasses HTTP(S)/SOCKS proxies.
  final WebRtcPolicy webRtcPolicy;
  /// Per-site proxy. Carried into:
  ///
  /// - The native webview proxy: on iOS 17+ / macOS 14+ via
  ///   [`inapp.InAppWebViewSettings.proxySettings`] (per-container
  ///   `WKWebsiteDataStore.proxyConfigurations`); on Android via the
  ///   process-wide `inapp.ProxyController` (last-write-wins under
  ///   container mode — see PROXY-008 in
  ///   [openspec/specs/proxy/spec.md] for the asymmetry).
  /// - Every Dart-side outbound call originating from this site
  ///   (downloads, user-script fetches), where it resolves through
  ///   `resolveEffectiveProxy` so [ProxyType.DEFAULT] falls through to
  ///   the app-global outbound proxy.
  final UserProxySettings? proxySettings;

  WebViewConfig({
    this.key,
    this.siteId,
    required this.initialUrl,
    this.javascriptEnabled = true,
    this.userAgent,
    this.thirdPartyCookiesEnabled = false,
    this.incognito = false,
    this.language,
    this.clearUrlEnabled = true,
    this.dnsBlockEnabled = true,
    this.contentBlockEnabled = true,
    this.localCdnEnabled = true,
    this.onUrlChanged,
    this.onLoadingChanged,
    this.onCookiesChanged,
    this.cookieManager,
    this.containerCookieManager,
    this.cookieSiteId,
    this.onFindResult,
    this.shouldOverrideUrlLoading,
    this.onWindowRequested,
    this.onHtmlLoaded,
    this.shouldFetchHtml,
    this.initialHtml,
    this.onConsoleMessage,
    this.userScripts = const [],
    this.onConfirmScriptFetch,
    this.onExternalSchemeUrl,
    this.pullToRefreshController,
    this.locationMode = LocationMode.off,
    this.spoofLatitude,
    this.spoofLongitude,
    this.spoofAccuracy = 50.0,
    this.spoofTimezone,
    this.spoofTimezoneFromLocation = false,
    this.webRtcPolicy = WebRtcPolicy.defaultPolicy,
    this.proxySettings,
  });
}

/// Controller interface for webview operations
abstract class WebViewController {
  /// The underlying `inapp.InAppWebViewController` this wrapper is
  /// bound to. Exposed so per-site code paths can pass it as the
  /// `webViewController:` argument to `inapp.CookieManager` methods,
  /// which the WebSpace fork uses to resolve the WebView's bound
  /// container and route cookie ops to its per-container jar.
  inapp.InAppWebViewController get nativeController;

  Future<void> loadUrl(String url, {String? language});
  Future<void> loadHtmlString(String html, {String? baseUrl});
  Future<void> reload();
  Future<Uri?> getUrl();
  Future<String?> getTitle();
  Future<String?> getHtml();
  Future<void> evaluateJavascript(String source);
  /// Evaluate [source] and return whatever the JS expression produced,
  /// JSON-decoded by the platform plugin into a Dart `dynamic`.
  /// Distinct from
  /// [evaluateJavascript] which suffixes the source with `null;` to
  /// neutralize WebKit's "unsupported return type" errors and so
  /// always resolves to `null`.
  Future<Object?> evaluateJavascriptReturning(String source);
  Future<void> findAllAsync({required String find});
  Future<void> findNext({required bool forward});
  Future<void> clearMatches();
  Future<String?> getDefaultUserAgent();
  Future<void> setOptions({
    required bool javascriptEnabled,
    String? userAgent,
    bool? thirdPartyCookiesEnabled,
    bool? incognito,
  });
  Future<void> setThemePreference(WebViewTheme theme);
  /// Update the page-text zoom (percent, 100 = unscaled). Used to track
  /// system "font size" accessibility changes after the webview is created.
  Future<void> setTextZoom(int zoomPercent);
  Future<void> goBack();
  Future<bool> canGoBack();
  /// Per-instance pause to reduce resource usage.
  ///
  /// On Android: calls `WebView.onPause()`, which is a best-effort pause of
  /// animations and geolocation. **Does NOT pause JavaScript** — Android only
  /// pauses JS via the process-global `pauseTimers()`, which we do not call
  /// here because it would also freeze every other loaded webview.
  ///
  /// On iOS: calls `pauseTimers()`, which the plugin implements per-instance
  /// via an `alert()`-deadlock hack that blocks this WebView's main JS thread.
  ///
  /// Activity that keeps running while paused on **both** platforms:
  ///   - Web Workers and Service Workers
  ///   - network requests already in flight (and any `Set-Cookie` they return)
  ///   - media playback (`<video>` / `<audio>` decoders)
  ///   - WebRTC peer connections, WebSocket frames over the wire
  ///
  /// `pause()` is for resource saving. It is **not a security boundary** — a
  /// page can observe cookies being deleted or proxy being swapped while
  /// paused (e.g. via a Service Worker fetch, or via `document.cookie` diff
  /// on the next `visibilitychange`). To safely mutate global state under
  /// a webview, dispose it instead.
  Future<void> pause();

  /// Resume a previously paused webview.
  Future<void> resume();

  /// Pause JavaScript timers (`setTimeout`/`setInterval`/`requestAnimationFrame`)
  /// process-globally on Android, per-instance on iOS.
  ///
  /// On Android, `WebView.pauseTimers()` is documented as global across all
  /// loaded WebViews. Use this only when the whole app is going to background;
  /// do **not** use it to pause a single site, otherwise you also freeze the
  /// site that's about to become active.
  Future<void> pauseAllJsTimers();

  /// Inverse of [pauseAllJsTimers].
  Future<void> resumeAllJsTimers();

  /// Abort any in-flight main-frame load. Used to quiesce chromium
  /// before queuing a follow-up navigation, shrinking the overlap
  /// between in-flight teardown and the next loadUrl.
  Future<void> stopLoading();
}

/// InAppWebView controller wrapper
class _WebViewController implements WebViewController {
  final inapp.InAppWebViewController _c;
  _WebViewController(this._c);

  @override
  inapp.InAppWebViewController get nativeController => _c;

  @override
  Future<void> loadUrl(String url, {String? language}) {
    final headers = <String, String>{};
    // HTTP headers are only meaningful for http(s) schemes. Attaching them to
    // non-HTTP URLs (chrome://, about:, file://, data:, javascript:) routes
    // the request through the WebView's HTTP path and can get rejected as
    // "invalid URL".
    final isHttp = url.startsWith('http://') || url.startsWith('https://');
    if (language != null && isHttp) {
      headers['Accept-Language'] = '$language, *;q=0.5';
    }
    return _c.loadUrl(
      urlRequest: inapp.URLRequest(
        url: inapp.WebUri(url),
        headers: headers.isNotEmpty ? headers : null,
      ),
    );
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) {
    return _c.loadData(
      data: html,
      mimeType: 'text/html',
      encoding: 'utf-8',
      baseUrl: baseUrl != null ? inapp.WebUri(baseUrl) : null,
    );
  }

  @override
  Future<void> reload() => _c.reload();

  @override
  Future<Uri?> getUrl() => _c.getUrl();

  @override
  Future<String?> getTitle() => _c.getTitle();

  @override
  Future<String?> getHtml() => _c.getHtml();

  @override
  Future<void> evaluateJavascript(String source) async {
    try {
      await _c.evaluateJavascript(source: '$source\n;null;');
    } catch (_) {} // WebKit "unsupported type" — JS still ran
  }

  @override
  Future<Object?> evaluateJavascriptReturning(String source) async {
    try {
      return await _c.evaluateJavascript(source: source);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> findAllAsync({required String find}) => _c.findAllAsync(find: find);

  @override
  Future<void> findNext({required bool forward}) => _c.findNext(forward: forward);

  @override
  Future<void> clearMatches() => _c.clearMatches();

  @override
  Future<String?> getDefaultUserAgent() async {
    try {
      return await inapp.InAppWebViewController.getDefaultUserAgent();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> setOptions({
    required bool javascriptEnabled,
    String? userAgent,
    bool? thirdPartyCookiesEnabled,
    bool? incognito,
  }) => _c.setSettings(
    settings: inapp.InAppWebViewSettings(
      javaScriptEnabled: javascriptEnabled,
      userAgent: userAgent,
      thirdPartyCookiesEnabled: thirdPartyCookiesEnabled ?? false,
      incognito: incognito ?? false,
      // Preserve system-derived textZoom — the InAppWebViewSettings
      // constructor defaults it to 100 and toMap always emits it, so any
      // setSettings call without this resets the user's font scale.
      textZoom: WebViewFactory.systemTextZoomPercent(),
      supportZoom: true,
      useShouldOverrideUrlLoading: true,
      // Enable multiple windows for Cloudflare Turnstile and other challenges
      supportMultipleWindows: true,
      domStorageEnabled: true,
      databaseEnabled: true,
      javaScriptCanOpenWindowsAutomatically: true,
      // Enable DevTools inspection in debug mode
      isInspectable: kDebugMode,
    ),
  );

  @override
  Future<void> setThemePreference(WebViewTheme theme) async {
    final themeValue = theme == WebViewTheme.system ? 'system' : (theme == WebViewTheme.dark ? 'dark' : 'light');
    await evaluateJavascript(_themeInjectionScript(themeValue));
  }

  @override
  Future<void> setTextZoom(int zoomPercent) async {
    if (Platform.isAndroid) {
      await _c.setSettings(
        settings: inapp.InAppWebViewSettings(textZoom: zoomPercent),
      );
      return;
    }
    // iOS/macOS: WKWebView has no textZoom setting. Rotate the
    // DOCUMENT_START user script so future page loads pick up the new
    // value, then update the style element on the current page.
    final source = '${WebViewFactory._textSizeAdjustScript(zoomPercent)}\n;null;';
    try {
      await _c.removeUserScriptsByGroupName(groupName: 'system_text_zoom');
      await _c.addUserScript(userScript: inapp.UserScript(
        groupName: 'system_text_zoom',
        source: source,
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
    } catch (_) {} // controller may be detached during teardown
    await evaluateJavascript(WebViewFactory._textSizeAdjustScript(zoomPercent));
  }

  @override
  Future<void> goBack() => _c.goBack();

  @override
  Future<bool> canGoBack() => _c.canGoBack();

  @override
  Future<void> pause() async {
    if (Platform.isAndroid) {
      // Android: per-instance only. pauseTimers() is process-global and would
      // freeze every other loaded WebView too — see [pauseAllJsTimers].
      await _c.pause();
    } else if (Platform.isIOS) {
      // iOS has no per-instance native pause; pauseTimers() is the plugin's
      // per-instance alert()-deadlock hack and is safe to call on one site.
      await _c.pauseTimers();
    }
  }

  @override
  Future<void> resume() async {
    if (Platform.isAndroid) {
      await _c.resume();
    } else if (Platform.isIOS) {
      await _c.resumeTimers();
    }
  }

  @override
  Future<void> pauseAllJsTimers() => _c.pauseTimers();

  @override
  Future<void> resumeAllJsTimers() => _c.resumeTimers();

  @override
  Future<void> stopLoading() async {
    await _c.stopLoading();
  }
}

String _themeInjectionScript(String themeValue) => '''
(function() {
  let actualTheme = '$themeValue';
  if (actualTheme === 'system') {
    actualTheme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  window.__appThemePreference = actualTheme;
  if (!window.__originalMatchMedia) {
    window.__originalMatchMedia = window.matchMedia.bind(window);
  }
  window.matchMedia = function(query) {
    const originalResult = window.__originalMatchMedia(query);
    if (query.includes('prefers-color-scheme')) {
      const isDarkQuery = query.includes('dark');
      const isLightQuery = query.includes('light');
      const appIsDark = window.__appThemePreference === 'dark';
      let matches = isDarkQuery ? appIsDark : (isLightQuery ? !appIsDark : false);
      return {
        matches: matches,
        media: query,
        onchange: null,
        addEventListener: function(type, listener) {
          if (type === 'change') {
            window.__themeChangeListeners = window.__themeChangeListeners || [];
            window.__themeChangeListeners.push({ query: query, listener: listener });
          }
        },
        removeEventListener: function(type, listener) {
          if (type === 'change' && window.__themeChangeListeners) {
            window.__themeChangeListeners = window.__themeChangeListeners.filter(item => item.listener !== listener);
          }
        },
        addListener: function(listener) { this.addEventListener('change', listener); },
        removeListener: function(listener) { this.removeEventListener('change', listener); }
      };
    }
    return originalResult;
  };
  let metaTag = document.querySelector('meta[name="color-scheme"]');
  if (!metaTag) {
    metaTag = document.createElement('meta');
    metaTag.name = 'color-scheme';
    document.head.appendChild(metaTag);
  }
  metaTag.content = actualTheme;
  document.documentElement.style.colorScheme = actualTheme;
  if (window.__themeChangeListeners) {
    window.__themeChangeListeners.forEach(item => {
      const isDarkQuery = item.query.includes('dark');
      const isLightQuery = item.query.includes('light');
      const appIsDark = window.__appThemePreference === 'dark';
      let matches = isDarkQuery ? appIsDark : (isLightQuery ? !appIsDark : false);
      try { item.listener({ matches: matches, media: item.query }); } catch (e) {}
    });
  }
})();
''';

/// JavaScript that disables every entry-point JS has into WebGL context
/// creation, so chromium never enters its WebGL-blocklist code path —
/// the suspect for a dangling-raw_ptr SIGTRAP at
/// `partition_alloc_support.cc:770` on the Android System WebView build
/// our crash logs come from. Injected at DOCUMENT_START into every
/// frame on Android only (see WebViewFactory.createWebView).
///
/// Coverage:
///   - HTMLCanvasElement.prototype.getContext('webgl' | 'webgl2' |
///     'experimental-webgl' | 'experimental-webgl2') → null
///   - OffscreenCanvas.prototype.getContext same treatment
///   - window.WebGLRenderingContext / WebGL2RenderingContext deleted so
///     `typeof WebGLRenderingContext === 'undefined'` feature detection
///     short-circuits before getContext is even attempted
const String _webGlKillSwitchScript = r'''
(function() {
  var GL_TYPES = {
    'webgl': 1, 'webgl2': 1,
    'experimental-webgl': 1, 'experimental-webgl2': 1
  };
  function patchGetContext(proto) {
    if (!proto || !proto.getContext) return;
    var orig = proto.getContext;
    proto.getContext = function(type) {
      if (typeof type === 'string' && GL_TYPES[type.toLowerCase()]) {
        return null;
      }
      return orig.apply(this, arguments);
    };
  }
  try { patchGetContext(HTMLCanvasElement.prototype); } catch (_) {}
  try {
    if (typeof OffscreenCanvas !== 'undefined') {
      patchGetContext(OffscreenCanvas.prototype);
    }
  } catch (_) {}
  try { delete window.WebGLRenderingContext; } catch (_) {}
  try { delete window.WebGL2RenderingContext; } catch (_) {}
})();
''';

/// JavaScript that intercepts clipboard writes and Web Share API calls to clean
/// tracking parameters from URLs before they leave the webview. Sends URLs to
/// Dart via the 'clearUrl' handler for cleaning with ClearURLs rules.
const String _clearUrlShareScript = r'''
(function() {
  const URL_RE = /^https?:\/\//i;

  // Intercept navigator.clipboard.writeText
  if (navigator.clipboard && navigator.clipboard.writeText) {
    const origWriteText = navigator.clipboard.writeText.bind(navigator.clipboard);
    navigator.clipboard.writeText = async function(text) {
      if (typeof text === 'string' && URL_RE.test(text.trim())) {
        try {
          const cleaned = await window.flutter_inappwebview.callHandler('clearUrl', text.trim());
          if (typeof cleaned === 'string' && cleaned.length > 0) {
            text = cleaned;
          }
        } catch (e) {}
      }
      return origWriteText(text);
    };
  }

  // Intercept navigator.share (Web Share API)
  if (navigator.share) {
    const origShare = navigator.share.bind(navigator);
    navigator.share = async function(data) {
      if (data && typeof data === 'object') {
        const cleaned = Object.assign({}, data);
        if (typeof cleaned.url === 'string' && URL_RE.test(cleaned.url)) {
          try {
            const r = await window.flutter_inappwebview.callHandler('clearUrl', cleaned.url);
            if (typeof r === 'string' && r.length > 0) cleaned.url = r;
          } catch (e) {}
        }
        if (typeof cleaned.text === 'string' && URL_RE.test(cleaned.text.trim())) {
          try {
            const r = await window.flutter_inappwebview.callHandler('clearUrl', cleaned.text.trim());
            if (typeof r === 'string' && r.length > 0) cleaned.text = r;
          } catch (e) {}
        }
        return origShare(cleaned);
      }
      return origShare(data);
    };
  }

  // Intercept document.execCommand('copy') by cleaning selected text if it's a URL
  const origExecCommand = document.execCommand.bind(document);
  document.execCommand = function(command, showUI, value) {
    if (command === 'copy') {
      const selection = window.getSelection();
      if (selection && selection.toString) {
        const text = selection.toString().trim();
        if (URL_RE.test(text)) {
          // Use async clipboard API to write the cleaned URL instead
          window.flutter_inappwebview.callHandler('clearUrl', text).then(function(cleaned) {
            if (typeof cleaned === 'string' && cleaned.length > 0 && cleaned !== text) {
              navigator.clipboard.writeText(cleaned).catch(function() {});
            }
          }).catch(function() {});
        }
      }
    }
    return origExecCommand(command, showUI, value);
  };
})();
''';

/// JavaScript that overrides `navigator.language`, `navigator.languages`, and
/// `Intl.DateTimeFormat().resolvedOptions().locale` so JS-side locale resolvers
/// (React i18n, date formatters) see the per-site language instead of the OS
/// locale. Must be injected at DOCUMENT_START to beat the page's own JS.
String _languageOverrideScript(String language) {
  // Use JSON encoding so the tag is safely escaped into the JS literal.
  final encoded = jsonEncode(language);
  return '''
(function() {
  try {
    var lang = $encoded;
    var langs = Object.freeze([lang]);
    Object.defineProperty(Navigator.prototype, 'language', {
      configurable: true, get: function() { return lang; }
    });
    Object.defineProperty(Navigator.prototype, 'languages', {
      configurable: true, get: function() { return langs; }
    });
    if (typeof Intl !== 'undefined' && Intl.DateTimeFormat) {
      var proto = Intl.DateTimeFormat.prototype;
      var orig = proto.resolvedOptions;
      proto.resolvedOptions = function() {
        var r = orig.apply(this, arguments);
        r.locale = lang;
        return r;
      };
    }
  } catch (e) {}
})();
''';
}


/// Method channel for WebAuthn/passkey support (Android only).
const MethodChannel _webAuthnChannel =
    MethodChannel('org.codeberg.theoden8.webspace/webauthn');

/// JavaScript polyfill for WebAuthn/passkey support.
///
/// Injected at DOCUMENT_START on Android. The polyfill:
///   - Defines `PublicKeyCredential` if it doesn't exist and always
///     overrides its static methods (isUserVerifyingPlatformAuthenticatorAvailable
///     returns true, isConditionalMediationAvailable returns false).
///   - Saves originals of `navigator.credentials.create/get`.
///   - Defines bridge functions that serialize options (ArrayBuffer to
///     Base64URL) and call `window.flutter_inappwebview.callHandler('webauthn', ...)`
///   - Overrides create/get to TRY NATIVE FIRST (call origCreate), and on
///     failure fall back to bridge.
///   - Uses `__webauthnPolyfilled` guard to prevent double-override of
///     create/get (but detection methods are always set).
const String _webAuthnPolyfillScript = r'''
(function() {
  // --- Detection: always override (no guard) ---
  if (typeof PublicKeyCredential === 'undefined') {
    window.PublicKeyCredential = function() {};
    window.PublicKeyCredential.prototype = {};
  }
  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = function() {
    return Promise.resolve(true);
  };
  PublicKeyCredential.isConditionalMediationAvailable = function() {
    return Promise.resolve(false);
  };

  // Guard create/get override
  if (window.__webauthnPolyfilled) return;
  window.__webauthnPolyfilled = true;

  console.log('[WebAuthn polyfill] installing create/get overrides');

  // --- Helpers ---
  function bufferToBase64url(buffer) {
    var bytes = new Uint8Array(buffer instanceof ArrayBuffer ? buffer : buffer.buffer);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }

  function base64urlToBuffer(base64url) {
    var base64 = base64url.replace(/-/g, '+').replace(/_/g, '/');
    while (base64.length % 4) base64 += '=';
    var binary = atob(base64);
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }

  function serializeCreateOptions(options) {
    var pk = options.publicKey;
    if (!pk) return JSON.stringify(options);
    var obj = JSON.parse(JSON.stringify(pk, function(key, value) {
      if (value && value.buffer instanceof ArrayBuffer) {
        return bufferToBase64url(value);
      }
      if (value instanceof ArrayBuffer) {
        return bufferToBase64url(value);
      }
      return value;
    }));
    if (pk.challenge) obj.challenge = bufferToBase64url(pk.challenge);
    if (pk.user && pk.user.id) obj.user.id = bufferToBase64url(pk.user.id);
    if (pk.excludeCredentials) {
      obj.excludeCredentials = pk.excludeCredentials.map(function(c) {
        var r = Object.assign({}, c);
        if (c.id) r.id = bufferToBase64url(c.id);
        return r;
      });
    }
    return JSON.stringify(obj);
  }

  function serializeGetOptions(options) {
    var pk = options.publicKey;
    if (!pk) return JSON.stringify(options);
    var obj = JSON.parse(JSON.stringify(pk, function(key, value) {
      if (value && value.buffer instanceof ArrayBuffer) {
        return bufferToBase64url(value);
      }
      if (value instanceof ArrayBuffer) {
        return bufferToBase64url(value);
      }
      return value;
    }));
    if (pk.challenge) obj.challenge = bufferToBase64url(pk.challenge);
    if (pk.allowCredentials) {
      obj.allowCredentials = pk.allowCredentials.map(function(c) {
        var r = Object.assign({}, c);
        if (c.id) r.id = bufferToBase64url(c.id);
        return r;
      });
    }
    return JSON.stringify(obj);
  }

  // --- Bridge functions ---
  function bridgeCreate(options) {
    console.log('[WebAuthn polyfill] bridge create');
    var requestJson = serializeCreateOptions(options);
    var origin = window.location.origin;
    return window.flutter_inappwebview.callHandler('webauthn', 'create', requestJson, origin)
      .then(function(responseJson) {
        console.log('[WebAuthn polyfill] bridge create response received');
        var resp = JSON.parse(responseJson);
        var credential = {
          id: resp.id || '',
          rawId: resp.rawId ? base64urlToBuffer(resp.rawId) : new ArrayBuffer(0),
          type: resp.type || 'public-key',
          response: {
            clientDataJSON: resp.response && resp.response.clientDataJSON
              ? base64urlToBuffer(resp.response.clientDataJSON)
              : new ArrayBuffer(0),
            attestationObject: resp.response && resp.response.attestationObject
              ? base64urlToBuffer(resp.response.attestationObject)
              : new ArrayBuffer(0),
            getTransports: function() { return resp.response && resp.response.transports || []; },
            getAuthenticatorData: function() {
              return resp.response && resp.response.authenticatorData
                ? base64urlToBuffer(resp.response.authenticatorData)
                : new ArrayBuffer(0);
            },
            getPublicKey: function() {
              return resp.response && resp.response.publicKey
                ? base64urlToBuffer(resp.response.publicKey)
                : null;
            },
            getPublicKeyAlgorithm: function() {
              return resp.response && resp.response.publicKeyAlgorithm || -7;
            }
          },
          authenticatorAttachment: resp.authenticatorAttachment || 'platform',
          getClientExtensionResults: function() { return resp.clientExtensionResults || {}; }
        };
        return credential;
      });
  }

  function bridgeGet(options) {
    console.log('[WebAuthn polyfill] bridge get');
    var requestJson = serializeGetOptions(options);
    var origin = window.location.origin;
    return window.flutter_inappwebview.callHandler('webauthn', 'get', requestJson, origin)
      .then(function(responseJson) {
        console.log('[WebAuthn polyfill] bridge get response received');
        var resp = JSON.parse(responseJson);
        var credential = {
          id: resp.id || '',
          rawId: resp.rawId ? base64urlToBuffer(resp.rawId) : new ArrayBuffer(0),
          type: resp.type || 'public-key',
          response: {
            clientDataJSON: resp.response && resp.response.clientDataJSON
              ? base64urlToBuffer(resp.response.clientDataJSON)
              : new ArrayBuffer(0),
            authenticatorData: resp.response && resp.response.authenticatorData
              ? base64urlToBuffer(resp.response.authenticatorData)
              : new ArrayBuffer(0),
            signature: resp.response && resp.response.signature
              ? base64urlToBuffer(resp.response.signature)
              : new ArrayBuffer(0),
            userHandle: resp.response && resp.response.userHandle
              ? base64urlToBuffer(resp.response.userHandle)
              : null
          },
          authenticatorAttachment: resp.authenticatorAttachment || 'platform',
          getClientExtensionResults: function() { return resp.clientExtensionResults || {}; }
        };
        return credential;
      });
  }

  // --- Override create/get: try native first, fall back to bridge ---
  var origCreate = navigator.credentials && navigator.credentials.create
    ? navigator.credentials.create.bind(navigator.credentials) : null;
  var origGet = navigator.credentials && navigator.credentials.get
    ? navigator.credentials.get.bind(navigator.credentials) : null;

  if (navigator.credentials) {
    navigator.credentials.create = function(options) {
      if (!options || !options.publicKey) {
        return origCreate ? origCreate(options) : Promise.reject(new Error('No publicKey in options'));
      }
      if (origCreate) {
        console.log('[WebAuthn polyfill] trying native create first');
        return origCreate(options).catch(function(err) {
          console.log('[WebAuthn polyfill] native create failed (' + err.message + '), falling back to bridge');
          return bridgeCreate(options);
        });
      }
      return bridgeCreate(options);
    };
    navigator.credentials.get = function(options) {
      if (!options || !options.publicKey) {
        return origGet ? origGet(options) : Promise.reject(new Error('No publicKey in options'));
      }
      if (origGet) {
        console.log('[WebAuthn polyfill] trying native get first');
        return origGet(options).catch(function(err) {
          console.log('[WebAuthn polyfill] native get failed (' + err.message + '), falling back to bridge');
          return bridgeGet(options);
        });
      }
      return bridgeGet(options);
    };
  }
})();
''';

/// Factory for creating webviews
class WebViewFactory {
  /// System font scale → webview text zoom percent. Tracks the OS-level
  /// "font size" accessibility setting so web content matches the size
  /// users see in their system browser.
  static int systemTextZoomPercent() {
    final scale = WidgetsBinding.instance.platformDispatcher.textScaleFactor;
    return (scale * 100).round();
  }

  /// CSS injected on iOS/macOS where WKWebView has no `textZoom` setting.
  /// `-webkit-text-size-adjust` is the closest equivalent — it scales text
  /// without resizing images. Sites that hard-pin it to 100% still win.
  static String _textSizeAdjustCss(int zoomPercent) =>
      'html{-webkit-text-size-adjust:$zoomPercent% !important;}';

  static String _textSizeAdjustScript(int zoomPercent) => '''
(function(){
  var id='__webspace_text_zoom__';
  var css='${_textSizeAdjustCss(zoomPercent)}';
  function apply(){
    var el=document.getElementById(id);
    if(!el){
      el=document.createElement('style');
      el.id=id;
      (document.head||document.documentElement).appendChild(el);
    }
    el.textContent=css;
  }
  if(document.documentElement){apply();}
  else{document.addEventListener('DOMContentLoaded',apply);}
})();''';

  /// Determine if a navigation was triggered by a user gesture.
  /// Android: uses hasGesture property.
  /// iOS/macOS: uses navigationType (LINK_ACTIVATED = user tap, FORM_SUBMITTED = user form).
  static bool _hasUserGesture(inapp.NavigationAction action) {
    if (Platform.isAndroid) {
      return action.hasGesture ?? true;
    }
    if (Platform.isIOS || Platform.isMacOS) {
      return action.navigationType == inapp.NavigationType.LINK_ACTIVATED ||
             action.navigationType == inapp.NavigationType.FORM_SUBMITTED;
    }
    return true; // Default allow on unknown platforms
  }

  static bool _shouldBlockUrl(String url) {
    // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile
    if (url.startsWith('about:') && url != 'about:blank' && url != 'about:srcdoc') return true;
    if (url.contains('/sw_iframe.html') || url.contains('/blank.html') || url.contains('/service_worker/')) return true;
    return false;
  }

  static const _captchaDomains = [
    'challenges.cloudflare.com',
    'hcaptcha.com',
  ];

  /// Domains that legitimately serve reCAPTCHA at /recaptcha/ paths.
  static const _recaptchaDomains = [
    'google.com',
    'gstatic.com',
    'recaptcha.net',
    'googleapis.com',
  ];

  static bool _matchesDomain(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  @visibleForTesting
  static bool isCaptchaChallenge(String url) {
    // Cloudflare path-based checks (only on Cloudflare-controlled paths)
    if (url.contains('cdn-cgi/challenge-platform') ||
        url.contains('cf-turnstile')) {
      return true;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) return false;
    final host = uri.host;
    if (host.isEmpty) return false;
    // Exact captcha domains (hcaptcha, Cloudflare challenges)
    if (_captchaDomains.any((d) => _matchesDomain(host, d))) return true;
    // reCAPTCHA: /recaptcha/ path only on known Google-owned domains
    if (uri.path.contains('/recaptcha/') &&
        _recaptchaDomains.any((d) => _matchesDomain(host, d))) {
      return true;
    }
    return false;
  }

  /// Create a popup webview for handling window.open() calls.
  /// Used for Cloudflare challenges and other popups that require a real window.
  static Widget createPopupWebView({
    required int windowId,
    VoidCallback? onCloseWindow,
  }) {
    final textZoom = systemTextZoomPercent();
    return inapp.InAppWebView(
      windowId: windowId,
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        textZoom: textZoom,
        // Enable browser-level resource caching for offline sub-resource loading
        cacheEnabled: true,
        // Enable DevTools inspection in debug mode (chrome://inspect on Android)
        isInspectable: kDebugMode,
      ),
      initialUserScripts: Platform.isAndroid ? null : UnmodifiableListView([
        inapp.UserScript(
          groupName: 'system_text_zoom',
          source: '${_textSizeAdjustScript(textZoom)}\n;null;',
          injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
          forMainFrameOnly: false,
        ),
      ]),
      onCloseWindow: (controller) {
        onCloseWindow?.call();
      },
    );
  }

  static Widget createWebView({
    required WebViewConfig config,
    required Function(WebViewController) onControllerCreated,
  }) {
    // Build initial URL request with optional Accept-Language header
    final headers = <String, String>{};
    if (config.language != null) {
      headers['Accept-Language'] = '${config.language}, *;q=0.5';
    }

    // Cached-HTML render: when the call site supplies
    // `config.initialHtml`, feed it to chromium via
    // `InAppWebViewInitialData(data, baseUrl: initialUrl)` for instant
    // first paint. Once the cached parse settles (`onLoadStop` for the
    // initialData), fire a one-shot `controller.reload()` to fetch the
    // live URL — which is `baseUrl`, so chromium re-loads the same
    // origin without losing the cached visual state during the
    // network round-trip.
    //
    // file:// imports are the exception — their initialUrl is a
    // synthetic `file://<filename>` handle with no fetchable form, so
    // we render the cache and never reload to live.
    //
    // The reload-to-live swap is what triggers the chromium
    // `partition_alloc_support.cc:770` dangling-raw_ptr SIGTRAP we
    // chased for many commits. That FATAL is gated by the
    // `PartitionAllocUnretainedDanglingPtr` chromium feature flag —
    // enabled on AOSP userdebug builds (where this branch was
    // originally tested), disabled in production Stable WebView.
    // Production users get the speed-up of cached first paint without
    // the dev-only crash.
    final isFileImport = config.initialUrl.startsWith('file://');
    final usesCachedHtml = config.initialHtml != null;
    // One-shot: when the cached HTML's first onLoadStop fires, do
    // exactly one controller.reload() to get a live page. Subsequent
    // onLoadStop events (post-reload, or for SPA navigations) leave
    // it false. Skip entirely for file:// imports and for builds
    // where we KNOW we're offline at construction (no live to fetch).
    var pendingLiveReload = usesCachedHtml && !isFileImport;

    final textZoom = systemTextZoomPercent();

    final userScripts = <inapp.UserScript>[];

    // WebGL kill-switch (Android). LinkedIn's `protechts.net`
    // fingerprint script (and other sites) try to create a WebGL
    // context on every page; on this device's WebView build that
    // walks a chromium code path with a dangling-raw_ptr regression
    // and SIGTRAPs the renderer at `partition_alloc_support.cc:770`.
    // `hardwareAcceleration: false` does NOT prevent this — chromium
    // still walks the WebGL blocklist code path even with software
    // compositing — and there's no `disableWebGL` flag in
    // InAppWebViewSettings. The only mechanism that actually works
    // is shimming the JS API so getContext() returns null for WebGL
    // types, which means JS never asks for the context and chromium
    // never enters the blocklist cleanup path.
    //
    // iOS/macOS WebKit doesn't have the regression, so leave WebGL
    // alone there.
    if (Platform.isAndroid) {
      userScripts.add(inapp.UserScript(
        groupName: 'webgl_kill_switch',
        source: '$_webGlKillSwitchScript\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        // Inject into every frame — third-party fingerprint scripts
        // routinely run inside iframes.
        forMainFrameOnly: false,
      ));
    }

    // Desktop-mode inference: a per-site UA without mobile markers
    // ("Android" / "iPhone" / "Mobile" etc) is treated as desktop, and
    // we inject the shim that patches navigator.userAgentData /
    // maxTouchPoints / matchMedia / viewport so feature-detecting sites
    // see a coherent desktop fingerprint instead of an Android-mobile one
    // with a desktop UA glued on top. Runs at DOCUMENT_START so the
    // shim's properties are in place before any site script reads them.
    final desktopMode = isDesktopUserAgent(config.userAgent);
    if (desktopMode) {
      userScripts.add(inapp.UserScript(
        groupName: 'desktop_mode_shim',
        source: '${buildDesktopModeShim(config.userAgent ?? '')}\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        // Inject into iframes too. Without this, a site can embed
        // browserleaks.com or similar in an iframe and bypass the shim
        // (iOS WKUserScript defaults to main-frame-only).
        forMainFrameOnly: false,
      ));
    }

    // System text zoom for non-Android: WKWebView has no `textZoom`
    // setting, so inject CSS that pushes -webkit-text-size-adjust.
    if (!Platform.isAndroid) {
      userScripts.add(inapp.UserScript(
        groupName: 'system_text_zoom',
        source: '${_textSizeAdjustScript(textZoom)}\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ));
    }

    // Resolve the effective spoof timezone. If the user picked
    // "From picked location" AND the polygon dataset is loaded AND there
    // are coordinates, look up the IANA zone here so the JS shim sees a
    // concrete value. If the dataset is missing or the lookup misses
    // (e.g. open ocean in the no-oceans dataset), fall through to
    // no-timezone-spoof rather than failing the whole shim.
    String? effectiveSpoofTimezone = config.spoofTimezone;
    if (config.spoofTimezoneFromLocation &&
        config.spoofLatitude != null &&
        config.spoofLongitude != null) {
      effectiveSpoofTimezone = TimezoneLocationService.instance
          .lookup(config.spoofLatitude!, config.spoofLongitude!);
    }

    // Location / timezone / WebRTC shim — must run FIRST so overrides are
    // in place before any site script can capture the unpatched references.
    final locationShim = LocationSpoofService.buildScript(
      locationMode: config.locationMode,
      spoofLatitude: config.spoofLatitude,
      spoofLongitude: config.spoofLongitude,
      spoofAccuracy: config.spoofAccuracy,
      spoofTimezone: effectiveSpoofTimezone,
      webRtcPolicy: config.webRtcPolicy,
    );
    if (locationShim != null) {
      userScripts.add(inapp.UserScript(
        groupName: 'location_spoof',
        source: '$locationShim\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        // Inject into every frame (iOS WKUserScript defaults to main-frame
        // only). Without this a site could embed browserleaks.com in an
        // iframe and bypass the spoof.
        forMainFrameOnly: false,
      ));
    }

    // Inject content blocker CSS at DOCUMENT_START so elements are hidden
    // before they ever render, eliminating the flash of unstyled content.
    if (config.contentBlockEnabled) {
      final earlyScript = ContentBlockerService.instance.getEarlyCssScript(config.initialUrl);
      if (earlyScript != null) {
        userScripts.add(inapp.UserScript(
          source: '$earlyScript\n;null;',
          injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        ));
      }
    }

    // ClearURLs: intercept clipboard writes and Web Share API to clean tracking
    // parameters from shared URLs before they leave the webview.
    if (config.clearUrlEnabled) {
      userScripts.add(inapp.UserScript(
        groupName: 'clearurl_share',
        source: '$_clearUrlShareScript\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // WebAuthn/passkey polyfill (Android only). Injects a JS shim that
    // overrides navigator.credentials.create/get to try the native WebAuthn
    // path first, falling back to the Credential Manager bridge via
    // flutter_inappwebview JS handler.
    if (Platform.isAndroid) {
      userScripts.add(inapp.UserScript(
        groupName: 'webauthn_polyfill',
        source: '$_webAuthnPolyfillScript\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // Override navigator.language / navigator.languages so client-rendered
    // SPAs (Bluesky, etc.) pick up the per-site language instead of the OS
    // locale. The Accept-Language header alone doesn't reach JS-side locale
    // resolvers. Must run at DOCUMENT_START before the page's JS reads it.
    if (config.language != null) {
      userScripts.add(inapp.UserScript(
        groupName: 'language_override',
        source: '${_languageOverrideScript(config.language!)}\n;null;',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // Block stats: inject PerformanceObserver to report loaded resource
    // URLs so allowed requests show up in the per-site log on iOS/macOS.
    // On Android, the native FastSubresourceInterceptor reports events
    // directly, so skip PerformanceObserver to avoid double-counting.
    // Always inject when siteId is set — stats are recorded based on user
    // intent to visit the site, not on whether blocklists are populated.
    final hasDnsRules = DnsBlockService.instance.hasBlocklist;
    final hasAbpRules =
        ContentBlockerService.instance.blockedDomains.isNotEmpty;
    if (!Platform.isAndroid && config.siteId != null) {
      userScripts.add(inapp.UserScript(
        groupName: 'block_resource_observer',
        source: '''
(function() {
  var seen = {};
  var pending = [];
  function send(url) {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('blockResourceLoaded', url);
    } else {
      pending.push(url);
    }
  }
  function report(url) {
    if (!url || seen[url] || !url.startsWith('http')) return;
    seen[url] = 1;
    send(url);
  }
  var po = new PerformanceObserver(function(list) {
    list.getEntries().forEach(function(e) { report(e.name); });
  });
  po.observe({type: 'resource', buffered: true});
  po.observe({type: 'navigation', buffered: true});
  function flush() {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      setTimeout(flush, 50);
      return;
    }
    pending.forEach(function(url) {
      window.flutter_inappwebview.callHandler('blockResourceLoaded', url);
    });
    pending = [];
  }
  flush();
})();
;null;''',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // iOS sub-resource blocking: JS interceptor with merged DNS+ABP
    // Bloom-filter prefilter. Bloom check is pure JS (microseconds).
    // Only ~0.1% of allowed URLs trigger a Dart roundtrip; Dart's
    // blockCheck handler decides DNS vs ABP and records the source.
    if (!Platform.isAndroid
        && config.siteId != null
        && ((config.dnsBlockEnabled && hasDnsRules) ||
            (config.contentBlockEnabled && hasAbpRules))) {
      userScripts.add(inapp.UserScript(
        groupName: 'block_js_interceptor',
        source: '''
(function() {
  var bloomReady = false;
  var bloomBits = null;
  var bloomBitCount = 0;
  var bloomK = 0;

  // FNV-1a 32-bit hash, matching Dart implementation
  function fnv1a(s, seed) {
    var h = seed >>> 0;
    for (var i = 0; i < s.length; i++) {
      h ^= s.charCodeAt(i);
      h = Math.imul(h, 16777619) >>> 0;
    }
    return h >>> 0;
  }

  function bloomContains(s) {
    if (!bloomReady) return true; // safe default while loading: ask Dart
    var h1 = fnv1a(s, 0x811C9DC5);
    var h2 = fnv1a(s, 0xCBF29CE4);
    for (var i = 0; i < bloomK; i++) {
      var pos = ((h1 + i * h2) >>> 0) % bloomBitCount;
      if ((bloomBits[pos >> 3] & (1 << (pos & 7))) === 0) return false;
    }
    return true;
  }

  // Hierarchy walk-up: check host, then each parent suffix
  function maybeBlocked(host) {
    if (bloomContains(host)) return true;
    var parts = host.split('.');
    for (var i = 1; i < parts.length - 1; i++) {
      if (bloomContains(parts.slice(i).join('.'))) return true;
    }
    return false;
  }

  // Per-site domain result cache (LRU-ish: evict oldest when full).
  // Restored from Dart persistence on startup, sent back on page load.
  var allowedCache = {};
  var blockedCache = {};
  var cacheKeys = [];
  var MAX_CACHE = 500;

  function cacheResult(host, blocked) {
    if (blocked) { blockedCache[host] = 1; }
    else { allowedCache[host] = 1; }
    cacheKeys.push(host);
    if (cacheKeys.length > MAX_CACHE) {
      var old = cacheKeys.shift();
      delete allowedCache[old];
      delete blockedCache[old];
    }
  }


  function check(url) {
    if (!url || typeof url !== 'string' || !url.startsWith('http')) {
      return Promise.resolve(false);
    }
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      return Promise.resolve(false);
    }
    var host;
    try { host = new URL(url).hostname; } catch (e) { return Promise.resolve(false); }
    // Check per-site cache first (instant)
    if (allowedCache[host]) return Promise.resolve(false);
    if (blockedCache[host]) return Promise.resolve(true);
    // Bloom prefilter: if definitely not in set, allow without roundtrip
    if (!maybeBlocked(host)) {
      cacheResult(host, false);
      window.flutter_inappwebview.callHandler('blockResourceLoaded', url);
      return Promise.resolve(false);
    }
    // Possibly blocked — confirm via Dart, then cache result. Dart
    // decides DNS vs ABP and records the source in per-site stats.
    return window.flutter_inappwebview.callHandler('blockCheck', url).then(function(blocked) {
      cacheResult(host, blocked);
      return blocked;
    });
  }

  // Fetch merged DNS+ABP Bloom filter + persisted per-site cache from
  // Dart at startup.
  function loadBloom() {
    if (!window.flutter_inappwebview || !window.flutter_inappwebview.callHandler) {
      setTimeout(loadBloom, 50);
      return;
    }
    window.flutter_inappwebview.callHandler('getBlockBloom').then(function(map) {
      if (!map) return;
      var bytes = map.bits;
      bloomBits = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
      bloomBitCount = map.bitCount;
      bloomK = map.k;
      // Restore persisted per-site cache
      var persisted = map.cache;
      if (persisted) {
        for (var h in persisted) {
          if (persisted[h]) blockedCache[h] = 1;
          else allowedCache[h] = 1;
          cacheKeys.push(h);
        }
      }
      bloomReady = true;
    });
  }
  loadBloom();

  // fetch
  var origFetch = window.fetch;
  if (origFetch) {
    window.fetch = function(input, init) {
      var url = typeof input === 'string' ? input : (input && input.url);
      return check(url).then(function(blocked) {
        if (blocked) return Promise.reject(new TypeError('Blocked by DNS blocklist: ' + url));
        return origFetch.call(this, input, init);
      }.bind(this));
    };
  }

  // XMLHttpRequest
  var origOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url) {
    this.__dnsBlockUrl = url;
    return origOpen.apply(this, arguments);
  };
  var origSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    var self = this;
    var args = arguments;
    check(self.__dnsBlockUrl).then(function(blocked) {
      if (blocked) { try { self.abort(); } catch(e) {} return; }
      origSend.apply(self, args);
    });
  };

  // Property setters for src/href on resource elements
  function patchSetter(proto, attr) {
    var desc = Object.getOwnPropertyDescriptor(proto, attr);
    if (!desc || !desc.set) return;
    var origSet = desc.set;
    Object.defineProperty(proto, attr, {
      configurable: true,
      enumerable: desc.enumerable,
      get: desc.get,
      set: function(value) {
        var el = this;
        check(value).then(function(blocked) {
          if (!blocked) origSet.call(el, value);
        });
      }
    });
  }
  patchSetter(HTMLImageElement.prototype, 'src');
  patchSetter(HTMLScriptElement.prototype, 'src');
  patchSetter(HTMLLinkElement.prototype, 'href');
  patchSetter(HTMLIFrameElement.prototype, 'src');

  // MutationObserver for statically-parsed HTML elements
  function checkElement(el) {
    var attr = null;
    if (el.tagName === 'IMG' || el.tagName === 'SCRIPT' || el.tagName === 'IFRAME') attr = 'src';
    else if (el.tagName === 'LINK') attr = 'href';
    if (attr) {
      var url = el.getAttribute(attr);
      if (url && url.indexOf('http') === 0) {
        check(url).then(function(blocked) {
          if (blocked) {
            el.removeAttribute(attr);
            if (el.parentNode) el.parentNode.removeChild(el);
          }
        });
      }
    }
  }
  var mo = new MutationObserver(function(mutations) {
    for (var i = 0; i < mutations.length; i++) {
      var added = mutations[i].addedNodes;
      for (var j = 0; j < added.length; j++) {
        var node = added[j];
        if (node.nodeType !== 1) continue;
        checkElement(node);
        if (node.querySelectorAll) {
          var els = node.querySelectorAll('img, script, link, iframe');
          for (var k = 0; k < els.length; k++) checkElement(els[k]);
        }
      }
    }
  });
  function startObserving() {
    if (document.documentElement) {
      mo.observe(document.documentElement, {childList: true, subtree: true});
    } else {
      setTimeout(startObserving, 10);
    }
  }
  startObserving();
})();
;null;''',
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // User script injection: shim for external dependency resolution + scripts
    final userScriptService = UserScriptService(
      scripts: config.userScripts,
      onConfirmScriptFetch: config.onConfirmScriptFetch,
      proxy: config.proxySettings,
    );
    userScripts.addAll(userScriptService.buildInitialUserScripts());

    // Track last URL that triggered onLoadStart, used to distinguish
    // SPA navigations (pushState) from real page loads in onUpdateVisitedHistory.
    String? lastLoadStartUrl;

    // Track the last URL that actually finished loading as a renderable
    // page. Updated via DownloadUrlRevertEngine.updateStable in
    // onLoadStop; consumed by the onDownloadStartRequest revert so the
    // URL bar and persisted currentUrl roll back to the referring page.
    // Initial-load fallback is handled inside the engine.
    String? lastStableUrl;

    // Monotonic counter bumped on every `shouldOverrideUrlLoading`
    // entry — i.e. every time chromium asks us about a new navigation,
    // including the synthetic invocations chromium fires for
    // server-side 3xx redirects. `onLoadStart` captures this value at
    // entry; if a later `shouldOverrideUrlLoading` bumps the counter
    // before we finish issuing IPCs against the previous frame, we bail
    // out of the remaining work. The previous frame is being torn down
    // and any further `evaluateJavascript` we post against it is bound
    // with `Unretained` lifetimes that the chromium IO thread later
    // dereferences after the frame is freed — exactly the
    // dangling-raw_ptr SIGTRAP at `partition_alloc_support.cc:770`
    // that this branch has been chasing.
    var navigationGen = 0;

    // iOS Universal Link bypass state (per-WebView). Tracks URLs we
    // just cancelled-and-reissued so the second-pass shouldOverrideUrlLoading
    // call (the reissued programmatic load landing here again) doesn't
    // loop. See lib/services/ios_universal_link_bypass.dart.
    final iosUlBypass = IosUniversalLinkBypass();

    // Container API binding. Stock flutter_inappwebview's `prepare()`
    // does session-bound ops (addJavascriptInterface,
    // addDocumentStartJavaScript, setAcceptThirdPartyCookies) BEFORE
    // `onWebViewCreated` fires, which locks the WebView to the default
    // store and made our earlier post-hoc-bind approach silently leak
    // across sites. The WebSpace fork's `containerId` field on
    // `InAppWebViewSettings` is read by `prepare()` /
    // `preWKWebViewConfiguration` and binds the WebView to the named
    // container before any session-bound op runs. `cachedSupported` is
    // already platform-aware (Windows / web fall through to the stub
    // which returns false); no extra Platform gate needed.
    final containerId = (ContainerNative.instance.cachedSupported &&
            config.siteId != null)
        ? 'ws-${config.siteId}'
        : null;

    // Per-site proxy delivery: only iOS 17+ / macOS 14+ honor the
    // per-WebView `proxySettings` field (which the fork's
    // `preWKWebViewConfiguration` writes onto
    // `WKWebsiteDataStore.proxyConfigurations`). On Android the global
    // `inapp.ProxyController` path runs from
    // `WebViewModel._applyProxySettings` instead, so leave
    // `proxySettings` null and avoid sending a no-op object to the
    // native side. resolveEffectiveProxy keeps the iOS/macOS WebView in
    // sync with the Dart-side and Android paths: per-site DEFAULT falls
    // through to the app-global outbound proxy, so a site the user
    // hasn't customized still inherits a global Tor / corporate proxy.
    // Explicit per-site values win.
    final inappProxy = (Platform.isIOS || Platform.isMacOS) &&
            config.proxySettings != null
        ? _userProxyToInappProxy(resolveEffectiveProxy(config.proxySettings!))
        : null;

    LogService.instance.log('DnsBlock', 'Creating webview: siteId=${config.siteId} dnsBlock=${config.dnsBlockEnabled} hasBlocklist=${DnsBlockService.instance.hasBlocklist} isAndroid=${Platform.isAndroid} url=${config.initialUrl} containerId=$containerId proxySettings=${inappProxy != null}');

    final settings = inapp.InAppWebViewSettings(
      containerId: containerId,
      proxySettings: inappProxy,
    )
      ..javaScriptEnabled = config.javascriptEnabled
      ..userAgent = config.userAgent
      ..thirdPartyCookiesEnabled = config.thirdPartyCookiesEnabled
      ..incognito = config.incognito
      ..textZoom = textZoom
      ..supportZoom = true
      ..useShouldOverrideUrlLoading = true
      // Keep the Dart shouldInterceptRequest callback disabled on Android:
      // the native FastSubresourceInterceptor handles DNS blocking and
      // LocalCDN replacement for every sub-resource, whereas the Dart
      // callback only fires for main-document navigations on modern
      // Chromium WebView.
      ..useShouldInterceptRequest = false
      ..useShouldInterceptAjaxRequest = false
      ..useShouldInterceptFetchRequest = false
      ..useOnLoadResource = false
      ..supportMultipleWindows = true
      // Required for Cloudflare Turnstile and other challenge systems
      ..domStorageEnabled = true
      ..databaseEnabled = true
      ..javaScriptCanOpenWindowsAutomatically = true
      // Android: allow file and content access for Cloudflare Turnstile
      ..allowFileAccess = true
      ..allowContentAccess = true
      // Enable browser-level resource caching for offline sub-resource loading
      ..cacheEnabled = true
      // When cached HTML is used, set cache-first mode from the start so
      // sub-resources (CSS/JS/images) resolve from browser cache immediately
      ..cacheMode = usesCachedHtml ? inapp.CacheMode.LOAD_CACHE_ELSE_NETWORK : null
      // iOS: play videos inline instead of auto-fullscreen
      ..allowsInlineMediaPlayback = true
      // Required for onDownloadStartRequest to fire when the webview
      // navigates to a downloadable response (Content-Disposition:
      // attachment, or an unrecognized MIME type). Without this, the
      // webview silently drops the navigation and the user sees nothing.
      ..useOnDownloadStart = true
      // Desktop content mode mirrors the per-site UA: a desktop-shaped UA
      // turns on the plugin's `setDesktopMode(true)` path, which flips
      // useWideViewPort + loadWithOverviewMode + zoom on Android and
      // WKWebpagePreferences.preferredContentMode = .desktop on iOS. The
      // shim above handles the JS-side touch / userAgentData patches.
      ..preferredContentMode = desktopMode
          ? inapp.UserPreferredContentMode.DESKTOP
          : inapp.UserPreferredContentMode.RECOMMENDED
      // Enable DevTools inspection in debug mode (chrome://inspect on Android)
      ..isInspectable = kDebugMode;

    return inapp.InAppWebView(
      key: config.key,
      initialUrlRequest: usesCachedHtml ? null : inapp.URLRequest(
        url: inapp.WebUri(config.initialUrl),
        headers: headers.isNotEmpty ? headers : null,
      ),
      initialData: usesCachedHtml ? inapp.InAppWebViewInitialData(
        data: config.initialHtml!,
        mimeType: 'text/html',
        encoding: 'utf-8',
        baseUrl: inapp.WebUri(config.initialUrl),
      ) : null,
      pullToRefreshController: config.pullToRefreshController,
      initialUserScripts: UnmodifiableListView(userScripts),
      initialSettings: settings,
      onWebViewCreated: (controller) async {
        final wrappedController = _WebViewController(controller);
        onControllerCreated(wrappedController);
        // Live geolocation: forward navigator.geolocation calls from the
        // shim into the platform's native location service. Permission is
        // requested by the native plugin only when this handler is first
        // invoked — i.e. only when the page actually calls
        // getCurrentPosition / watchPosition. The handler returns a
        // serialisable map matching CurrentLocationService's JSON shape.
        if (config.locationMode == LocationMode.live) {
          controller.addJavaScriptHandler(
            handlerName: 'getRealLocation',
            callback: (args) async {
              final res = await CurrentLocationService.getCurrentLocation();
              if (res.status == CurrentLocationStatus.ok && res.fix != null) {
                return {
                  'status': 'ok',
                  'latitude': res.fix!.latitude,
                  'longitude': res.fix!.longitude,
                  'accuracy': res.fix!.accuracy,
                };
              }
              return {
                'status': res.status.name,
                'message': res.message ?? 'unknown',
              };
            },
          );
        }
        // Register ClearURLs handler for clipboard/share URL cleaning
        if (config.clearUrlEnabled) {
          controller.addJavaScriptHandler(handlerName: 'clearUrl', callback: (args) {
            if (args.isNotEmpty && args[0] is String) {
              return ClearUrlService.instance.cleanUrl(args[0] as String);
            }
            return args.isNotEmpty ? args[0] : '';
          });
        }
        // Block stats: register handler for resource observer JS. Always
        // register when siteId is set so allowed requests are tallied
        // regardless of whether any blocklist is populated — the JS
        // checks below decide how to attribute a block, and a request
        // with neither list matching is simply recorded as allowed.
        if (config.siteId != null) {
          controller.addJavaScriptHandler(handlerName: 'blockResourceLoaded', callback: (args) {
            if (args.isNotEmpty && args[0] is String) {
              final url = args[0] as String;
              final dnsBlocked = config.dnsBlockEnabled &&
                  DnsBlockService.instance.isBlocked(url);
              final abpBlocked = !dnsBlocked &&
                  config.contentBlockEnabled &&
                  ContentBlockerService.instance.isBlocked(url);
              final blocked = dnsBlocked || abpBlocked;
              final source = dnsBlocked
                  ? BlockSource.dns
                  : (abpBlocked ? BlockSource.abp : null);
              DnsBlockService.instance
                  .recordRequest(config.siteId!, url, blocked, source: source);
            }
            return null;
          });
          // iOS sub-resource blocking: per-URL check from JS interceptor.
          // Merged Bloom prefilter runs in JS; Dart resolves DNS vs ABP.
          if (!Platform.isAndroid) {
            controller.addJavaScriptHandler(handlerName: 'blockCheck', callback: (args) {
              if (args.isEmpty || args[0] is! String) return false;
              final url = args[0] as String;
              if (config.dnsBlockEnabled &&
                  DnsBlockService.instance.isBlocked(url)) {
                DnsBlockService.instance.recordRequest(
                    config.siteId!, url, true,
                    source: BlockSource.dns);
                return true;
              }
              if (config.contentBlockEnabled &&
                  ContentBlockerService.instance.isBlocked(url)) {
                DnsBlockService.instance.recordRequest(
                    config.siteId!, url, true,
                    source: BlockSource.abp);
                return true;
              }
              DnsBlockService.instance
                  .recordRequest(config.siteId!, url, false);
              return false;
            });
            // One-shot merged Bloom filter + global domain cache delivery to JS
            controller.addJavaScriptHandler(handlerName: 'getBlockBloom', callback: (args) {
              final map = Map<String, dynamic>.from(
                  DnsBlockService.instance.getMergedBlockBloom().toMap());
              map['cache'] = DnsBlockService.instance.getDomainCache();
              return map;
            });
          }
        }
        userScriptService.registerHandlers(controller);
        // Blob download: JS reads the blob via FileReader and hands the
        // base64 payload back through these handlers.
        controller.addJavaScriptHandler(
          handlerName: '_webspaceBlobDownload',
          callback: (args) async {
            if (args.length < 4) return null;
            final filename = args[0] is String ? args[0] as String : '';
            final base64Data = args[1] is String ? args[1] as String : '';
            final mimeType = args[2] is String ? args[2] as String : '';
            final taskId = args[3] is String ? args[3] as String : '';
            if (base64Data.isEmpty) {
              if (taskId.isNotEmpty) {
                DownloadsService.instance.fail(taskId, 'empty payload');
              }
              return null;
            }
            try {
              final result = DownloadEngine.fromBase64(
                base64Data: base64Data,
                suggestedFilename: filename.isEmpty ? null : filename,
                mimeType: mimeType.isEmpty ? null : mimeType,
              );
              if (taskId.isNotEmpty) {
                DownloadsService.instance.updateProgress(taskId,
                    bytesDone: result.bytes.length,
                    bytesTotal: result.bytes.length);
              }
              final saved = await _saveViaPicker(result);
              if (taskId.isNotEmpty) {
                if (saved == null) {
                  DownloadsService.instance.cancel(taskId);
                } else {
                  DownloadsService.instance
                      .complete(taskId, savedPath: saved);
                }
              }
            } on DownloadException catch (e) {
              if (taskId.isNotEmpty) {
                DownloadsService.instance.fail(taskId, e.message);
              }
            } catch (e, stack) {
              debugPrint('Blob download error: $e\n$stack');
              if (taskId.isNotEmpty) {
                DownloadsService.instance.fail(taskId, e.toString());
              }
            }
            return null;
          },
        );
        controller.addJavaScriptHandler(
          handlerName: '_webspaceBlobDownloadError',
          callback: (args) {
            final msg = args.isNotEmpty ? args[0].toString() : 'unknown';
            final taskId = args.length >= 2 && args[1] is String
                ? args[1] as String
                : '';
            if (taskId.isNotEmpty) {
              DownloadsService.instance.fail(taskId, msg);
            }
            return null;
          },
        );
        controller.addJavaScriptHandler(
          handlerName: '_webspaceBlobProgress',
          callback: (args) {
            if (args.length < 3) return null;
            final taskId = args[0] is String ? args[0] as String : '';
            final done = _asInt(args[1]);
            final total = _asInt(args[2]);
            if (taskId.isEmpty) return null;
            DownloadsService.instance.updateProgress(
              taskId,
              bytesDone: done,
              bytesTotal: total,
            );
            return null;
          },
        );
        // Cached-HTML → live-URL swap is wired up in onLoadStop below.
        // Don't fire loadUrl here — `onWebViewCreated` runs while chromium
        // is still parsing the initialData, and a synchronous loadUrl in
        // that window aborts the in-flight parse (load-while-loading),
        // which on Android System WebView trips a dangling-raw_ptr in the
        // renderer process at `partition_alloc_support.cc:770`.
        //
        // Container API bind happens natively inside the WebSpace fork's
        // `InAppWebView.prepare()`, driven by the `containerId` we set on
        // `InAppWebViewSettings` above. By the time `onWebViewCreated`
        // fires, the WebView is already bound to its per-site container
        // and every cookie / IDB / ServiceWorker / cache write that
        // follows is partitioned to that container.
        // WebAuthn/passkey: register JS handler and set up native WebAuthn
        // support on Android. The handler bridges navigator.credentials
        // create/get calls from the JS polyfill to the native Credential
        // Manager via the platform channel.
        if (Platform.isAndroid) {
          controller.addJavaScriptHandler(
            handlerName: 'webauthn',
            callback: (args) async {
              if (args.length < 3) return null;
              final action = args[0] as String;
              final requestJson = args[1] as String;
              final origin = args[2] as String;
              try {
                final result = await _webAuthnChannel.invokeMethod(action, {
                  'requestJson': requestJson,
                  'origin': origin,
                });
                return result;
              } on PlatformException catch (e) {
                throw Exception('WebAuthn $action failed: ${e.code} ${e.message}');
              }
            },
          );
          // Set up native WebAuthn support on the WebView after it's
          // been added to the view hierarchy.
          Future.microtask(() async {
            try {
              final info = await _webAuthnChannel.invokeMethod('setupWebAuthn');
              debugPrint('WebAuthn setup: $info');
            } catch (e) {
              debugPrint('WebAuthn setup failed: $e');
            }
          });
        }
        // Attach native interceptor (DNS blocking + LocalCDN serving) once
        // the view is in the hierarchy. Always attach on Android — the
        // handler no-ops cheaply when neither blocklist nor CDN cache are
        // populated, and the references are shared with the plugin so
        // subsequent updates are picked up without re-attaching.
        if (Platform.isAndroid) {
          Future.microtask(() => WebInterceptNative.attachToWebViews(siteId: config.siteId));
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        // Bump the navigation generation FIRST. Any in-flight `onLoadStart`
        // handler from the previous navigation that's about to fire an
        // `evaluateJavascript` IPC will see the advance and skip the call,
        // so the IPC isn't bound to a frame chromium is in the middle of
        // tearing down.
        navigationGen++;
        final url = navigationAction.request.url.toString();
        if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
        if (isCaptchaChallenge(url)) return inapp.NavigationActionPolicy.ALLOW;
        // External app schemes (intent://, tel:, mailto:, market:, custom
        // app schemes) can't be rendered in a webview — flutter_inappwebview
        // returns ERR_UNKNOWN_URL_SCHEME. Cancel and hand the URL to the
        // host UI, which confirms with the user before calling url_launcher.
        // Don't call controller.stopLoading() here — chromium has crashed
        // with a dangling raw_ptr when stopLoading runs concurrently with
        // a synchronous CANCEL path. The CANCEL alone aborts the
        // navigation; if Android still paints ERR_UNKNOWN_URL_SCHEME,
        // onReceivedError handles recovery.
        final externalInfo = ExternalUrlParser.parse(url);
        if (externalInfo != null) {
          LogService.instance.log('WebView',
              'External scheme intercepted: scheme=${externalInfo.scheme} '
              'package=${externalInfo.package} fallback=${externalInfo.fallbackUrl} url=$url');
          if (config.onExternalSchemeUrl != null) {
            config.onExternalSchemeUrl!(url, externalInfo);
          }
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // DNS blocklist check + record navigation for stats. Record for
        // every http navigation so the per-site log works even when no
        // blocklist is populated; isBlocked is a cheap set lookup.
        if (config.siteId != null && url.startsWith('http')) {
          LogService.instance.log('DnsBlock', '[Navigation] $url');
          final blocked = DnsBlockService.instance.hasBlocklist &&
              DnsBlockService.instance.isBlocked(url);
          DnsBlockService.instance.recordRequest(config.siteId!, url, blocked,
              source: blocked ? BlockSource.dns : null);
          if (blocked && config.dnsBlockEnabled) {
            return inapp.NavigationActionPolicy.CANCEL;
          }
        }
        // Content blocker domain check (main-doc navigation; sub-resources
        // are caught by the native / JS interceptor).
        if (config.contentBlockEnabled && ContentBlockerService.instance.isBlocked(url)) {
          if (config.siteId != null) {
            DnsBlockService.instance.recordRequest(config.siteId!, url, true,
                source: BlockSource.abp);
          }
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // ClearURLs: strip tracking parameters from URLs
        if (config.clearUrlEnabled && ClearUrlService.instance.hasRules) {
          final cleanedUrl = ClearUrlService.instance.cleanUrl(url);
          if (cleanedUrl.isEmpty) return inapp.NavigationActionPolicy.CANCEL;
          if (cleanedUrl != url) {
            controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(cleanedUrl)));
            return inapp.NavigationActionPolicy.CANCEL;
          }
        }
        // Cross-domain → nested-webview routing applies to MAIN-FRAME
        // navigations only. On Android API 24+ chromium fires
        // shouldOverrideUrlLoading for child-frame (iframe) navigations
        // as well, with `isForMainFrame == false` distinguishing them.
        // If we forwarded those into the engine we'd open every
        // embedded iframe (Google One Tap GSI, Cloudflare challenge
        // iframe, third-party SSO popups) as a separate top-level
        // webview — wrong, intrusive, and on Android can race the
        // chromium frame-lifecycle code path that the
        // `partition_alloc_support.cc:770` dangle ride sits on top
        // of. Allow iframe navigations to load in-place; the engine
        // sees only main-frame navigations.
        final isMainFrame = navigationAction.isForMainFrame ?? true;
        // Diagnostic: log the raw isForMainFrame so we can tell
        // when a platform reports null vs. true vs. false. WebKit2GTK
        // on Linux has been observed to return true for navigations
        // that originate from inside an iframe; Android API 24+
        // returns false for child-frame navigations consistently.
        LogService.instance.log('WebView',
            'shouldOverrideUrlLoading: isForMainFrame=${navigationAction.isForMainFrame}');
        if (!isMainFrame) {
          return inapp.NavigationActionPolicy.ALLOW;
        }
        if (config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(navigationAction);
          final allow = config.shouldOverrideUrlLoading!(url, hasGesture);
          if (!allow) return inapp.NavigationActionPolicy.CANCEL;
        }
        // iOS Universal Link bypass. WKWebView auto-routes user-tap
        // navigations (and redirect chains rooted in a tap) to the
        // native app for URLs whose host matches an installed app's
        // AASA — even when the user explicitly added the site to
        // WebSpace. iOS exposes no public API to detect AASA matches,
        // so the bypass treats every gesture-rooted main-frame
        // http(s) navigation as at-risk: cancel + reissue via
        // `loadUrl`. WebKit treats programmatic loads as navigation
        // type `.other` and skips AASA matching, keeping the page
        // inside the webview regardless of which apps are installed.
        // The reissued nav fires `shouldOverrideUrlLoading` again;
        // the per-URL memo passes that second pass through.
        //
        // Pure programmatic navigations (initial nav, server
        // redirects without a tap origin, pushState) carry no user
        // gesture — they don't activate AASA in the first place and
        // are passed through here without interception.
        if (Platform.isIOS &&
            isMainFrame &&
            url.startsWith('http') &&
            _hasUserGesture(navigationAction)) {
          if (iosUlBypass.shouldCancelAndReissue(url)) {
            LogService.instance.log('WebView',
                '  -> CANCEL (iOS UL bypass: reissuing programmatically) $url');
            // Forward original headers so per-site Accept-Language
            // survives the reissue. POST body is dropped — POSTs
            // that match AASA are rare and the existing flow lost
            // them anyway when iOS short-circuited to the native
            // app.
            final originalUrl = navigationAction.request.url;
            final originalHeaders = navigationAction.request.headers;
            controller.loadUrl(urlRequest: inapp.URLRequest(
              url: originalUrl,
              headers: originalHeaders,
            ));
            return inapp.NavigationActionPolicy.CANCEL;
          }
          LogService.instance.log('WebView',
              '  -> ALLOW (iOS UL bypass: reissued nav passing through)');
        }
        return inapp.NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (controller, createWindowAction) async {
        final url = createWindowAction.request.url?.toString() ?? '';
        final windowId = createWindowAction.windowId;
        LogService.instance.log('WebView',
            'onCreateWindow: url=$url windowId=$windowId');

        // Show popup dialog for Cloudflare challenges (captcha verification).
        if (isCaptchaChallenge(url)) {
          if (config.onWindowRequested != null && windowId != null) {
            await config.onWindowRequested!(windowId, url);
            return true;
          }
          return false;
        }

        // target="_blank" links can carry external app schemes too (e.g.
        // a `<a target="_blank" href="intent://...">`). Route them through
        // the same confirmation path as direct navigations.
        final externalInfo = ExternalUrlParser.parse(url);
        if (externalInfo != null) {
          LogService.instance.log('WebView',
              'External scheme intercepted (onCreateWindow): '
              'scheme=${externalInfo.scheme} package=${externalInfo.package} url=$url');
          if (config.onExternalSchemeUrl != null) {
            config.onExternalSchemeUrl!(url, externalInfo);
          }
          return false;
        }

        // For target="_blank" links (e.g., badge clicks on GitHub), delegate
        // to shouldOverrideUrlLoading which handles cross-domain navigation
        // by opening a nested webview. On iOS, target="_blank" links may
        // only trigger onCreateWindow without shouldOverrideUrlLoading.
        // Script-initiated window.open() (analytics, Stripe) have no user
        // gesture and are silently blocked by the auto-redirect check.
        if (url.startsWith('http') && config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(createWindowAction);
          final allow = config.shouldOverrideUrlLoading!(url, hasGesture);
          if (allow) {
            // Same-domain target="_blank": load in current webview
            controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(url)));
          }
        }

        return false;
      },
      // Dart shouldInterceptRequest is intentionally unset — see the
      // useShouldInterceptRequest comment above. Sub-resource DNS blocking
      // and LocalCDN replacement are both handled by the native
      // FastSubresourceInterceptor attached via WebInterceptNative.
      onLoadStart: (controller, url) async {
        // Snapshot the navigation generation BEFORE any await — if a
        // later `shouldOverrideUrlLoading` advances the counter while
        // we're between IPCs, the previous frame is being torn down and
        // we abandon the remaining work rather than post evaluateJS
        // against it. See the `navigationGen` comment above for why.
        final myGen = navigationGen;
        bool stillCurrent() => navigationGen == myGen;

        // Notify the call site that a navigation just started so the
        // Refresh button can swap to a Stop button while loading.
        config.onLoadingChanged?.call(true);

        // Track that this URL has a real page load (not SPA navigation)
        lastLoadStartUrl = url?.toString();
        // Record the page navigation for the block stats banner so it
        // appears immediately. Tag the source (DNS or ABP) so the log
        // keeps the attribution even for main-doc loads. Recorded for
        // every http load so the per-site log reflects activity even
        // when no blocklist is populated.
        if (config.siteId != null &&
            url != null &&
            url.toString().startsWith('http')) {
          final urlStr = url.toString();
          final dnsBlocked = DnsBlockService.instance.isBlocked(urlStr);
          final abpBlocked = !dnsBlocked &&
              ContentBlockerService.instance.isBlocked(urlStr);
          final blocked = dnsBlocked || abpBlocked;
          final source = dnsBlocked
              ? BlockSource.dns
              : (abpBlocked ? BlockSource.abp : null);
          DnsBlockService.instance
              .recordRequest(config.siteId!, urlStr, blocked, source: source);
        }
        // Batch the early-injected helpers (content-blocker CSS,
        // ClearURLs share-API shim) into a single evaluateJavascript
        // IPC. Two separate IPCs gave chromium two race windows per
        // onLoadStart; one IPC closes one of those windows entirely.
        // Both scripts are already self-contained IIFEs, so
        // concatenation is safe.
        final earlyScripts = <String>[];
        if (config.contentBlockEnabled && url != null) {
          final cssScript =
              ContentBlockerService.instance.getEarlyCssScript(url.toString());
          if (cssScript != null) earlyScripts.add(cssScript);
        }
        if (config.clearUrlEnabled) {
          earlyScripts.add(_clearUrlShareScript);
        }
        // Re-inject WebAuthn polyfill on each page load so the shim is
        // in place before any site script runs. The DOCUMENT_START user
        // script covers the initial load; this covers subsequent
        // navigations within the same WebView instance.
        if (Platform.isAndroid) {
          earlyScripts.add(_webAuthnPolyfillScript);
        }
        if (earlyScripts.isNotEmpty && stillCurrent()) {
          try {
            await controller.evaluateJavascript(
                source: '${earlyScripts.join('\n')}\n;null;');
          } catch (_) {} // WebKit "unsupported type" — JS still ran
        }
        if (stillCurrent()) {
          await userScriptService.reinjectOnLoadStart(controller);
        }
      },
      onLoadStop: (controller, url) async {
        // End pull-to-refresh animation
        config.pullToRefreshController?.endRefreshing();
        // Notify the call site that this navigation finished loading
        // (or was canceled) so the Stop button can swap back to
        // Refresh. Fired regardless of whether `url` is renderable —
        // the loading-state UI is independent of the cache/snapshot
        // logic gated below.
        config.onLoadingChanged?.call(false);
        if (url == null) return;
        final urlStr = url.toString();

        // Downloads, javascript: bookmarklets, and other non-renderable
        // schemes can reach here when controller.stopLoading() interrupts
        // an in-flight navigation (the download path does this to keep
        // the webview from rendering the attachment as a page). There's
        // no real page to snapshot — onHtmlLoaded would end up writing
        // either the previous page's HTML keyed under the download URL,
        // or empty content, clobbering a legitimate offline cache entry.
        // Skip all post-load work in that case; onDownloadStartRequest's
        // revert handles URL bar restoration.
        if (!DownloadUrlRevertEngine.isRenderable(urlStr)) return;

        // Cached-HTML one-shot live refresh. After the cached HTML
        // parse settles, fire a single `controller.reload()` to fetch
        // a fresh copy of the page over the network. The
        // `pendingLiveReload` flag is consumed on first use so the
        // subsequent (post-reload) onLoadStop doesn't recurse.
        //
        // Gated on `navigationGen == 0` — i.e. no shouldOverrideUrlLoading
        // has fired yet. If the user clicked anything during the cached
        // parse, gen > 0 and we skip the reload; their navigation is the
        // current intent. (`reload()` itself does not bump
        // navigationGen on Android WebView.)
        //
        // Skipped for offline runs via the `isOnline()` check — there's
        // no live to fetch, so the cached page is the answer.
        if (pendingLiveReload && navigationGen == 0) {
          pendingLiveReload = false;
          ConnectivityService.instance.isOnline().then((online) {
            if (!online) return;
            try {
              controller.reload();
            } catch (_) {}
          });
        }

        lastStableUrl =
            DownloadUrlRevertEngine.updateStable(lastStableUrl, urlStr);
        config.onUrlChanged?.call(urlStr);
        if (config.onCookiesChanged != null) {
          // Read cookies from the right jar — exactly one of the two
          // managers is non-null per the engine selection on
          // `_WebSpacePageState`. containerCookieManager routes through
          // the fork's `webViewController:` to the bound container's
          // cookie store; cookieManager hits the global default jar.
          final List<Cookie> cookies;
          if (config.containerCookieManager != null && config.cookieSiteId != null) {
            cookies = await config.containerCookieManager!.getCookies(
              controller: _WebViewController(controller),
              siteId: config.cookieSiteId!,
              url: Uri.parse(urlStr),
            );
          } else {
            assert(
              config.cookieManager != null,
              'onCookiesChanged requires cookieManager (legacy mode) '
              'or containerCookieManager + cookieSiteId (container mode).',
            );
            cookies = await config.cookieManager!.getCookies(
              url: Uri.parse(urlStr),
            );
          }
          config.onCookiesChanged!(cookies);
        }
        // Inject full cosmetic script: MutationObserver + text-based hiding
        if (config.contentBlockEnabled) {
          final script = ContentBlockerService.instance.getCosmeticScript(urlStr);
          if (script != null) {
            try {
              await controller.evaluateJavascript(source: '$script\n;null;');
            } catch (_) {} // WebKit "unsupported type" — JS still ran
          }
        }
        await userScriptService.reinjectOnLoadStop(controller);
        // Cache HTML for offline viewing. Pre-gate the renderer IPC
        // via shouldFetchHtml so the per-onLoadStop storm is collapsed
        // before we ask chromium to serialize the DOM — the IPC, not
        // the encrypt+write afterward, is the lifecycle-racing piece.
        if (config.onHtmlLoaded != null
            && (config.shouldFetchHtml?.call() ?? true)) {
          try {
            final html = await controller.getHtml();
            if (html != null && html.isNotEmpty) {
              config.onHtmlLoaded!(urlStr, html);
            }
          } catch (_) {
            // Controller may have been disposed if webview was unloaded
          }
        }
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) {
        // Fires on every history change including back/forward gestures.
        // onLoadStop may not fire for BFCache restorations (iOS Safari back
        // gesture), so this ensures the URL bar stays in sync.
        if (url != null) {
          config.onUrlChanged?.call(url.toString());
          // SPA navigations (pushState/replaceState) don't trigger
          // onLoadStart/onLoadStop. Detect by checking if this URL had a
          // corresponding onLoadStart. If not, it's a SPA navigation —
          // re-run user scripts' source code (not the library).
          final urlStr = url.toString();
          if (urlStr != lastLoadStartUrl) {
            userScriptService.reinjectOnSpaNavigation(controller);
          }
          lastLoadStartUrl = null; // Reset for next navigation
        }
      },
      onFindResultReceived: (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        config.onFindResult?.call(activeMatchOrdinal, numberOfMatches);
      },
      onConsoleMessage: (controller, consoleMessage) {
        config.onConsoleMessage?.call(consoleMessage.message, consoleMessage.messageLevel);
      },
      onReceivedError: (controller, request, error) async {
        // For non-internal schemes (intent://, custom app schemes) Android
        // sometimes hands the URL straight to onReceivedError without
        // calling shouldOverrideUrlLoading first — observed every time on
        // Google Maps' window.location='intent://...' redirect. Without
        // routing through the dialog path here, the user never sees the
        // confirmation, suppression is never marked, and the previous
        // "reload lastStableUrl" recovery looped forever (every reload
        // re-renders the page that re-fires the same intent).
        //
        // New flow:
        //   * already suppressed → silent no-op (lets the page sit on
        //     whatever it managed to render before redirecting).
        //   * external scheme + host UI hooked up → fire the dialog
        //     callback; the helper guards against duplicate prompts and
        //     marks suppression on the user's choice.
        //   * external scheme + no host UI → best-effort reload.
        if (request.isForMainFrame != true) return;
        final reqUrl = request.url.toString();
        final externalInfo = ExternalUrlParser.parse(reqUrl);
        if (externalInfo == null) return;
        if (ExternalUrlSuppressor.isSuppressedInfo(externalInfo)) {
          LogService.instance.log('WebView',
              'onReceivedError: suppressed — loading about:blank to clear error commit (url=$reqUrl)');
          // The fallback page actually loaded (HtmlCache shows
          // multi-MB saves); Android then painted chrome-error://
          // chromewebdata over it because the page's JS retried the
          // intent we cancelled. about:blank clears the error visibly
          // without walking back through history (controller.goBack
          // dropped users out of the webview entirely). The
          // suppression already prevents another dialog if the page
          // tries again.
          Future.microtask(() async {
            try {
              await controller.loadUrl(
                urlRequest: inapp.URLRequest(url: inapp.WebUri('about:blank')),
              );
            } catch (_) {}
          });
          return;
        }
        if (config.onExternalSchemeUrl != null) {
          LogService.instance.log('WebView',
              'onReceivedError: type=${error.type} url=$reqUrl '
              '— routing to external-scheme dialog');
          config.onExternalSchemeUrl!(reqUrl, externalInfo);
          return;
        }
        final recovery = lastStableUrl ?? config.initialUrl;
        LogService.instance.log('WebView',
            'onReceivedError: type=${error.type} url=$reqUrl '
            '— no host UI, scheduling reload of $recovery');
        Future.microtask(() async {
          try {
            await controller.loadUrl(
              urlRequest: inapp.URLRequest(url: inapp.WebUri(recovery)),
            );
          } catch (_) {}
        });
      },
      onDownloadStartRequest: (controller, downloadStartRequest) async {
        // onUrlChanged / onUpdateVisitedHistory has likely already fired
        // with the download URL (e.g. "data:application/pdf;..."), which
        // would otherwise be persisted as the site's "current URL" and
        // tried again on next launch. Resolve the revert target BEFORE
        // awaiting the download so a nested callback can't clobber it,
        // then roll the URL bar back after stopLoading().
        final revert = DownloadUrlRevertEngine.pickRevertTarget(
          lastStableUrl: lastStableUrl,
          initialUrl: config.initialUrl,
        );
        await _handleDownloadRequest(
          controller,
          downloadStartRequest,
          referer: lastStableUrl ?? config.initialUrl,
          proxy: config.proxySettings,
        );
        if (revert != null) {
          config.onUrlChanged?.call(revert);
        }
      },
    );
  }

  static Future<void> _handleDownloadRequest(
    inapp.InAppWebViewController controller,
    inapp.DownloadStartRequest req, {
    String? referer,
    UserProxySettings? proxy,
  }) async {
    // Abort any in-flight main-frame navigation to this URL. Without this
    // the webview tries to render the attachment response as a page and
    // ends up on a "net::ERR_UNKNOWN_URL_SCHEME" / "invalid request" error
    // page while the URL bar is stuck on the download URL.
    try {
      await controller.stopLoading();
    } catch (_) {}

    final urlStr = req.url.toString();
    final scheme = req.url.scheme.toLowerCase();

    switch (scheme) {
      case 'http':
      case 'https':
        await _handleHttpDownload(req, referer: referer, proxy: proxy);
        return;
      case 'data':
        _handleDataDownload(req);
        return;
      case 'blob':
        await _handleBlobDownload(controller, urlStr, req.suggestedFilename);
        return;
      default:
        _showDownloadSnack('Can\'t download $scheme: URL.');
    }
  }

  static Future<void> _handleHttpDownload(
    inapp.DownloadStartRequest req, {
    String? referer,
    UserProxySettings? proxy,
  }) async {
    final initialFilename = DownloadEngine.deriveFilename(
      suggested: req.suggestedFilename,
      url: req.url.toString(),
      mimeType: req.mimeType,
    );
    final task = DownloadsService.instance.start(
      filename: initialFilename,
      url: req.url.toString(),
      bytesTotal: req.contentLength > 0 ? req.contentLength : null,
    );
    try {
      final cookies = await inapp.CookieManager.instance()
          .getCookies(url: req.url);
      final cookieHeader = DownloadEngine.buildCookieHeader(
        cookies.map((c) => MapEntry(c.name, c.value.toString())),
      );
      final engine = DownloadEngine(proxy: proxy);
      final result = await engine.fetch(
        url: req.url.toString(),
        cookieHeader: cookieHeader,
        userAgent: req.userAgent,
        referer: referer,
        suggestedFilename: req.suggestedFilename,
        mimeTypeHint: req.mimeType,
        onProgress: (done, total) => DownloadsService.instance
            .updateProgress(task.id, bytesDone: done, bytesTotal: total),
      );
      task.filename = result.filename;
      final savedPath = await _saveViaPicker(result);
      if (savedPath == null) {
        DownloadsService.instance.cancel(task.id);
      } else {
        DownloadsService.instance.complete(task.id, savedPath: savedPath);
      }
    } on DownloadException catch (e) {
      DownloadsService.instance.fail(task.id, e.message);
    } catch (e, stack) {
      debugPrint('Download error: $e\n$stack');
      DownloadsService.instance.fail(task.id, e.toString());
    }
  }

  static void _handleDataDownload(inapp.DownloadStartRequest req) async {
    final task = DownloadsService.instance.start(
      filename: req.suggestedFilename?.isNotEmpty == true
          ? req.suggestedFilename!
          : 'download',
      url: req.url.toString(),
    );
    try {
      final result = DownloadEngine.decodeDataUri(
        url: req.url.toString(),
        suggestedFilename: req.suggestedFilename,
      );
      task.filename = result.filename;
      DownloadsService.instance.updateProgress(task.id,
          bytesDone: result.bytes.length, bytesTotal: result.bytes.length);
      final savedPath = await _saveViaPicker(result);
      if (savedPath == null) {
        DownloadsService.instance.cancel(task.id);
      } else {
        DownloadsService.instance.complete(task.id, savedPath: savedPath);
      }
    } on DownloadException catch (e) {
      DownloadsService.instance.fail(task.id, e.message);
    } catch (e, stack) {
      debugPrint('Data-URI download error: $e\n$stack');
      DownloadsService.instance.fail(task.id, e.toString());
    }
  }

  static Future<void> _handleBlobDownload(
    inapp.InAppWebViewController controller,
    String blobUrl,
    String? suggestedFilename,
  ) async {
    final task = DownloadsService.instance.start(
      filename: suggestedFilename?.isNotEmpty == true
          ? suggestedFilename!
          : 'download',
      url: blobUrl,
    );
    // IIFE: fetch the blob, read via FileReader, hand the base64 back to
    // Dart. Result is delivered asynchronously through
    // _webspaceBlobDownload(filename, base64, mimeType). The taskId is
    // round-tripped through JS so the handler can resolve which task to
    // complete.
    final blobJson = jsonEncode(blobUrl);
    final fnJson = jsonEncode(suggestedFilename ?? '');
    final idJson = jsonEncode(task.id);
    final script = '''
(function(blobUrl, suggestedFilename, taskId) {
  function progress(done, total) {
    window.flutter_inappwebview.callHandler(
      '_webspaceBlobProgress', taskId, done, total);
  }
  try {
    fetch(blobUrl).then(function(r) { return r.blob(); }).then(function(blob) {
      var total = blob.size || 0;
      progress(0, total);
      var reader = new FileReader();
      reader.onprogress = function(e) {
        if (e && e.lengthComputable) {
          progress(e.loaded, e.total);
        }
      };
      reader.onload = function() {
        progress(total, total);
        var result = reader.result || '';
        var comma = result.indexOf(',');
        var base64 = comma === -1 ? '' : result.substring(comma + 1);
        window.flutter_inappwebview.callHandler(
          '_webspaceBlobDownload',
          suggestedFilename,
          base64,
          blob.type || '',
          taskId
        );
      };
      reader.onerror = function() {
        var msg = (reader.error && reader.error.message) || 'read error';
        window.flutter_inappwebview.callHandler(
          '_webspaceBlobDownloadError', msg, taskId);
      };
      reader.readAsDataURL(blob);
    }).catch(function(err) {
      window.flutter_inappwebview.callHandler(
        '_webspaceBlobDownloadError',
        (err && err.message) || String(err), taskId);
    });
  } catch (e) {
    window.flutter_inappwebview.callHandler(
      '_webspaceBlobDownloadError',
      (e && e.message) || String(e), taskId);
  }
})($blobJson, $fnJson, $idJson);
''';
    try {
      await controller.evaluateJavascript(source: script);
    } catch (e, stack) {
      debugPrint('Blob download eval error: $e\n$stack');
      DownloadsService.instance.fail(task.id, e.toString());
    }
  }

  static Future<String?> _saveViaPicker(DownloadResult result) async {
    final isMobile = !kIsWeb && (Platform.isIOS || Platform.isAndroid);
    final outputPath = await FilePicker.saveFile(
      dialogTitle: 'Save download',
      fileName: result.filename,
      bytes: isMobile ? result.bytes : null,
    );
    if (outputPath == null) return null;
    if (!isMobile) {
      final file = File(outputPath);
      await file.writeAsBytes(result.bytes);
    }
    return outputPath;
  }

  static void _showDownloadSnack(String message) {
    rootScaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Coerce a JS handler arg to an int. Small integers come back as int
  /// but large ones can arrive as double (JSON number serialization), so
  /// normalize both.
  static int? _asInt(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}
