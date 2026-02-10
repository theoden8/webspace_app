import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/settings/proxy.dart';

// Re-export inapp.Cookie as Cookie for convenience
typedef Cookie = inapp.Cookie;

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

/// Proxy manager singleton
class ProxyManager {
  static final ProxyManager _instance = ProxyManager._internal();
  factory ProxyManager() => _instance;
  ProxyManager._internal();

  Future<void> setProxySettings(UserProxySettings settings) async {
    if (!PlatformInfo.isProxySupported) return;

    final controller = inapp.ProxyController.instance();

    if (settings.type == ProxyType.DEFAULT) {
      await controller.clearProxyOverride();
      return;
    }

    if (settings.address == null || settings.address!.isEmpty) {
      throw Exception('Proxy address is required');
    }

    final parts = settings.address!.split(':');
    if (parts.length != 2) {
      throw Exception('Proxy address must be in format host:port');
    }

    final host = parts[0];
    final port = int.tryParse(parts[1]);
    if (port == null) {
      throw Exception('Invalid port number');
    }

    final scheme = switch (settings.type) {
      ProxyType.HTTPS => 'https',
      ProxyType.SOCKS5 => 'socks5',
      _ => 'http',
    };

    final proxyUrl = settings.hasCredentials
        ? '$scheme://${Uri.encodeComponent(settings.username!)}:${Uri.encodeComponent(settings.password!)}@$host:$port'
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
    await inapp.ProxyController.instance().clearProxyOverride();
  }
}

/// Platform info - proxy support detection
class PlatformInfo {
  static bool? _isProxySupportedCached;

  static Future<void> initialize() async {
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
  final Function(int activeMatch, int totalMatches)? onFindResult;
  final Function(String url, bool shouldAllow)? shouldOverrideUrlLoading;
  /// Callback for when a popup window is requested (e.g., Cloudflare challenges).
  /// Returns a widget (typically a WebView) to display in the popup.
  /// The callback receives the windowId for the popup and the requested URL.
  final Future<void> Function(int windowId, String url)? onWindowRequested;
  /// Callback when page HTML should be cached. Called on page load with (url, html).
  final Function(String url, String html)? onHtmlLoaded;
  /// Optional cached HTML to display immediately while the real URL loads.
  final String? initialHtml;

  WebViewConfig({
    this.key,
    required this.initialUrl,
    this.javascriptEnabled = true,
    this.userAgent,
    this.thirdPartyCookiesEnabled = false,
    this.incognito = false,
    this.language,
    this.onUrlChanged,
    this.onCookiesChanged,
    this.onFindResult,
    this.shouldOverrideUrlLoading,
    this.onWindowRequested,
    this.onHtmlLoaded,
    this.initialHtml,
  });
}

/// Controller interface for webview operations
abstract class WebViewController {
  Future<void> loadUrl(String url, {String? language});
  Future<void> loadHtmlString(String html, {String? baseUrl});
  Future<void> reload();
  Future<Uri?> getUrl();
  Future<String?> getTitle();
  Future<String?> getHtml();
  Future<void> evaluateJavascript(String source);
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
  Future<void> goBack();
  Future<bool> canGoBack();
}

/// InAppWebView controller wrapper
class _WebViewController implements WebViewController {
  final inapp.InAppWebViewController _c;
  _WebViewController(this._c);

  @override
  Future<void> loadUrl(String url, {String? language}) {
    final headers = <String, String>{};
    if (language != null) {
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
  Future<void> evaluateJavascript(String source) => _c.evaluateJavascript(source: source);

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
  Future<void> goBack() => _c.goBack();

  @override
  Future<bool> canGoBack() => _c.canGoBack();
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

/// Factory for creating webviews
class WebViewFactory {
  static const _trackingDomains = [
    'googletagmanager.com', 'google-analytics.com', 'googleadservices.com',
    'doubleclick.net', 'facebook.com/tr', 'connect.facebook.net',
    'analytics.twitter.com', 'static.ads-twitter.com',
  ];

  static bool _shouldBlockUrl(String url) {
    // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile
    if (url.startsWith('about:') && url != 'about:blank' && url != 'about:srcdoc') return true;
    if (url.contains('/sw_iframe.html') || url.contains('/blank.html') || url.contains('/service_worker/')) return true;
    return _trackingDomains.any((d) => url.contains(d));
  }

  static bool _isCloudflareChallenge(String url) =>
      url.contains('challenges.cloudflare.com') ||
      url.contains('cloudflare.com/cdn-cgi/challenge') ||
      url.contains('cdn-cgi/challenge-platform') ||
      url.contains('turnstile.com') ||
      url.contains('cf-turnstile');

  /// Create a popup webview for handling window.open() calls.
  /// Used for Cloudflare challenges and other popups that require a real window.
  static Widget createPopupWebView({
    required int windowId,
    VoidCallback? onCloseWindow,
  }) {
    return inapp.InAppWebView(
      windowId: windowId,
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        // Enable DevTools inspection in debug mode (chrome://inspect on Android)
        isInspectable: kDebugMode,
      ),
      onCloseWindow: (controller) {
        onCloseWindow?.call();
      },
    );
  }

  static Widget createWebView({
    required WebViewConfig config,
    required Function(WebViewController) onControllerCreated,
  }) {
    final cookieManager = inapp.CookieManager.instance();

    // Build initial URL request with optional Accept-Language header
    final headers = <String, String>{};
    if (config.language != null) {
      headers['Accept-Language'] = '${config.language}, *;q=0.5';
    }

    // Use cached HTML for instant display, or regular URL request
    final usesCachedHtml = config.initialHtml != null;

    return inapp.InAppWebView(
      key: config.key,
      // If we have cached HTML, load it first for instant display
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
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: config.javascriptEnabled,
        userAgent: config.userAgent,
        thirdPartyCookiesEnabled: config.thirdPartyCookiesEnabled,
        incognito: config.incognito,
        supportZoom: true,
        useShouldOverrideUrlLoading: true,
        supportMultipleWindows: true,
        // Required for Cloudflare Turnstile and other challenge systems
        domStorageEnabled: true,
        databaseEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        // Android: allow file and content access for Cloudflare Turnstile
        allowFileAccess: true,
        allowContentAccess: true,
        // Enable DevTools inspection in debug mode (chrome://inspect on Android)
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) {
        final wrappedController = _WebViewController(controller);
        onControllerCreated(wrappedController);
        // If we loaded cached HTML, now navigate to the real URL for fresh content
        if (usesCachedHtml) {
          wrappedController.loadUrl(config.initialUrl, language: config.language);
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url.toString();
        if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
        if (_isCloudflareChallenge(url)) return inapp.NavigationActionPolicy.ALLOW;
        if (config.shouldOverrideUrlLoading != null) {
          return config.shouldOverrideUrlLoading!(url, true)
              ? inapp.NavigationActionPolicy.ALLOW
              : inapp.NavigationActionPolicy.CANCEL;
        }
        return inapp.NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (controller, createWindowAction) async {
        final url = createWindowAction.request.url?.toString() ?? '';
        final windowId = createWindowAction.windowId;

        // If we have a callback for handling popups, use it
        if (config.onWindowRequested != null && windowId != null) {
          await config.onWindowRequested!(windowId, url);
          return true;
        }

        // For other popups without a handler, load in the same window instead
        if (url.isNotEmpty) {
          await controller.loadUrl(urlRequest: inapp.URLRequest(url: createWindowAction.request.url));
        }
        return false;
      },
      onLoadStop: (controller, url) async {
        if (url != null) {
          config.onUrlChanged?.call(url.toString());
          if (config.onCookiesChanged != null) {
            final cookies = await cookieManager.getCookies(url: inapp.WebUri(url.toString()));
            config.onCookiesChanged!(cookies);
          }
          // Cache HTML for offline viewing
          if (config.onHtmlLoaded != null) {
            final html = await controller.getHtml();
            if (html != null && html.isNotEmpty) {
              config.onHtmlLoaded!(url.toString(), html);
            }
          }
        }
      },
      onFindResultReceived: (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        config.onFindResult?.call(activeMatchOrdinal, numberOfMatches);
      },
    );
  }
}
