import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

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
  final Function(String url, bool hasGesture)? shouldOverrideUrlLoading;
  /// Callback for when a popup window is requested (e.g., Cloudflare challenges).
  /// Returns a widget (typically a WebView) to display in the popup.
  /// The callback receives the windowId for the popup and the requested URL.
  final Future<void> Function(int windowId, String url)? onWindowRequested;
  /// Callback when page HTML should be cached. Called on page load with (url, html).
  final Function(String url, String html)? onHtmlLoaded;
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
  /// Optional pull-to-refresh controller for enabling pull-to-refresh gesture.
  final inapp.PullToRefreshController? pullToRefreshController;

  WebViewConfig({
    this.key,
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
    this.onCookiesChanged,
    this.onFindResult,
    this.shouldOverrideUrlLoading,
    this.onWindowRequested,
    this.onHtmlLoaded,
    this.initialHtml,
    this.onConsoleMessage,
    this.userScripts = const [],
    this.pullToRefreshController,
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
  /// Pause the webview (stop rendering and JS execution).
  /// On Android this pauses the WebView entirely; on iOS it pauses timers.
  Future<void> pause();
  /// Resume a previously paused webview.
  Future<void> resume();
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

  @override
  Future<void> pause() async {
    if (Platform.isAndroid) {
      await _c.pause();
    }
    await _c.pauseTimers();
  }

  @override
  Future<void> resume() async {
    if (Platform.isAndroid) {
      await _c.resume();
    }
    await _c.resumeTimers();
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

/// Factory for creating webviews
class WebViewFactory {
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
    return inapp.InAppWebView(
      windowId: windowId,
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: true,
        supportZoom: true,
        domStorageEnabled: true,
        databaseEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        // Enable browser-level resource caching for offline sub-resource loading
        cacheEnabled: true,
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

    // Use cached HTML for offline display. Set cache mode from the start
    // so sub-resources (CSS/JS/images) resolve from browser HTTP cache.
    final usesCachedHtml = config.initialHtml != null;

    // Inject content blocker CSS at DOCUMENT_START so elements are hidden
    // before they ever render, eliminating the flash of unstyled content.
    final userScripts = <inapp.UserScript>[];
    if (config.contentBlockEnabled) {
      final earlyScript = ContentBlockerService.instance.getEarlyCssScript(config.initialUrl);
      if (earlyScript != null) {
        userScripts.add(inapp.UserScript(
          source: earlyScript,
          injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
        ));
      }
    }

    // ClearURLs: intercept clipboard writes and Web Share API to clean tracking
    // parameters from shared URLs before they leave the webview.
    if (config.clearUrlEnabled) {
      userScripts.add(inapp.UserScript(
        groupName: 'clearurl_share',
        source: _clearUrlShareScript,
        injectionTime: inapp.UserScriptInjectionTime.AT_DOCUMENT_START,
      ));
    }

    // Inject per-site user scripts
    for (final script in config.userScripts) {
      if (!script.enabled || script.source.isEmpty) continue;
      userScripts.add(inapp.UserScript(
        groupName: 'user_scripts',
        source: script.source,
        injectionTime: script.injectionTime == UserScriptInjectionTime.atDocumentStart
            ? inapp.UserScriptInjectionTime.AT_DOCUMENT_START
            : inapp.UserScriptInjectionTime.AT_DOCUMENT_END,
      ));
    }

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
      initialSettings: inapp.InAppWebViewSettings(
        javaScriptEnabled: config.javascriptEnabled,
        userAgent: config.userAgent,
        thirdPartyCookiesEnabled: config.thirdPartyCookiesEnabled,
        incognito: config.incognito,
        supportZoom: true,
        useShouldOverrideUrlLoading: true,
        useShouldInterceptRequest: config.localCdnEnabled && Platform.isAndroid,
        supportMultipleWindows: true,
        // Required for Cloudflare Turnstile and other challenge systems
        domStorageEnabled: true,
        databaseEnabled: true,
        javaScriptCanOpenWindowsAutomatically: true,
        // Android: allow file and content access for Cloudflare Turnstile
        allowFileAccess: true,
        allowContentAccess: true,
        // Enable browser-level resource caching for offline sub-resource loading
        cacheEnabled: true,
        // When cached HTML is used, set cache-first mode from the start so
        // sub-resources (CSS/JS/images) resolve from browser cache immediately
        cacheMode: usesCachedHtml ? inapp.CacheMode.LOAD_CACHE_ELSE_NETWORK : null,
        // iOS: play videos inline instead of auto-fullscreen
        allowsInlineMediaPlayback: true,
        // Enable DevTools inspection in debug mode (chrome://inspect on Android)
        isInspectable: kDebugMode,
      ),
      onWebViewCreated: (controller) async {
        final wrappedController = _WebViewController(controller);
        onControllerCreated(wrappedController);
        // Register ClearURLs handler for clipboard/share URL cleaning
        if (config.clearUrlEnabled) {
          controller.addJavaScriptHandler(handlerName: 'clearUrl', callback: (args) {
            if (args.isNotEmpty && args[0] is String) {
              return ClearUrlService.instance.cleanUrl(args[0] as String);
            }
            return args.isNotEmpty ? args[0] : '';
          });
        }
        // If we loaded cached HTML, navigate to the real URL when online
        if (usesCachedHtml) {
          final online = await ConnectivityService.instance.isOnline();
          if (online) {
            // Reset cache mode to default before loading live URL
            await controller.setSettings(settings: inapp.InAppWebViewSettings(
              cacheMode: inapp.CacheMode.LOAD_DEFAULT,
            ));
            wrappedController.loadUrl(config.initialUrl, language: config.language);
          }
        }
      },
      shouldOverrideUrlLoading: (controller, navigationAction) async {
        final url = navigationAction.request.url.toString();
        if (_shouldBlockUrl(url)) return inapp.NavigationActionPolicy.CANCEL;
        if (isCaptchaChallenge(url)) return inapp.NavigationActionPolicy.ALLOW;
        // DNS blocklist check
        if (config.dnsBlockEnabled && DnsBlockService.instance.isBlocked(url)) {
          return inapp.NavigationActionPolicy.CANCEL;
        }
        // Content blocker domain check
        if (config.contentBlockEnabled && ContentBlockerService.instance.isBlocked(url)) {
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
        if (config.shouldOverrideUrlLoading != null) {
          final hasGesture = _hasUserGesture(navigationAction);
          return config.shouldOverrideUrlLoading!(url, hasGesture)
              ? inapp.NavigationActionPolicy.ALLOW
              : inapp.NavigationActionPolicy.CANCEL;
        }
        return inapp.NavigationActionPolicy.ALLOW;
      },
      onCreateWindow: (controller, createWindowAction) async {
        final url = createWindowAction.request.url?.toString() ?? '';
        final windowId = createWindowAction.windowId;

        // Show popup dialog for Cloudflare challenges (captcha verification).
        if (isCaptchaChallenge(url)) {
          if (config.onWindowRequested != null && windowId != null) {
            await config.onWindowRequested!(windowId, url);
            return true;
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
      shouldInterceptRequest: config.localCdnEnabled && Platform.isAndroid
          ? (controller, request) async {
              final url = request.url.toString();
              final service = LocalCdnService.instance;
              if (!service.isCdnUrl(url)) return null;

              final data = await service.getOrFetchResource(url);
              if (data == null) return null;

              return inapp.WebResourceResponse(
                contentType: service.getContentType(url),
                contentEncoding: 'utf-8',
                data: data,
              );
            }
          : null,
      onLoadStart: (controller, url) async {
        // Re-inject CSS for in-page navigations (initialUserScripts only runs on first load)
        if (config.contentBlockEnabled && url != null) {
          final script = ContentBlockerService.instance.getEarlyCssScript(url.toString());
          if (script != null) {
            await controller.evaluateJavascript(source: script);
          }
        }
        // Re-inject ClearURLs share script for in-page navigations
        if (config.clearUrlEnabled) {
          await controller.evaluateJavascript(source: _clearUrlShareScript);
        }
        // Re-inject user scripts (atDocumentStart) for in-page navigations
        for (final script in config.userScripts) {
          if (!script.enabled || script.source.isEmpty) continue;
          if (script.injectionTime == UserScriptInjectionTime.atDocumentStart) {
            await controller.evaluateJavascript(source: script.source);
          }
        }
      },
      onLoadStop: (controller, url) async {
        // End pull-to-refresh animation
        config.pullToRefreshController?.endRefreshing();
        if (url != null) {
          config.onUrlChanged?.call(url.toString());
          if (config.onCookiesChanged != null) {
            final cookies = await cookieManager.getCookies(url: inapp.WebUri(url.toString()));
            config.onCookiesChanged!(cookies);
          }
          // Inject full cosmetic script: MutationObserver + text-based hiding
          if (config.contentBlockEnabled) {
            final script = ContentBlockerService.instance.getCosmeticScript(url.toString());
            if (script != null) {
              await controller.evaluateJavascript(source: script);
            }
          }
          // Re-inject user scripts (atDocumentEnd) for in-page navigations
          for (final script in config.userScripts) {
            if (!script.enabled || script.source.isEmpty) continue;
            if (script.injectionTime == UserScriptInjectionTime.atDocumentEnd) {
              await controller.evaluateJavascript(source: script.source);
            }
          }
          // Cache HTML for offline viewing
          if (config.onHtmlLoaded != null) {
            try {
              final html = await controller.getHtml();
              if (html != null && html.isNotEmpty) {
                config.onHtmlLoaded!(url.toString(), html);
              }
            } catch (_) {
              // Controller may have been disposed if webview was unloaded
            }
          }
        }
      },
      onUpdateVisitedHistory: (controller, url, androidIsReload) {
        // Fires on every history change including back/forward gestures.
        // onLoadStop may not fire for BFCache restorations (iOS Safari back
        // gesture), so this ensures the URL bar stays in sync.
        if (url != null) {
          config.onUrlChanged?.call(url.toString());
        }
      },
      onFindResultReceived: (controller, activeMatchOrdinal, numberOfMatches, isDoneCounting) {
        config.onFindResult?.call(activeMatchOrdinal, numberOfMatches);
      },
      onConsoleMessage: (controller, consoleMessage) {
        config.onConsoleMessage?.call(consoleMessage.message, consoleMessage.messageLevel);
      },
    );
  }
}
