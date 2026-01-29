import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show WebUri;
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';

/// Generates a unique site ID for per-site cookie isolation.
String _generateSiteId() {
  final now = DateTime.now().microsecondsSinceEpoch;
  final random = Random().nextInt(999999);
  return '${now.toRadixString(36)}-${random.toRadixString(36)}';
}

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

/// Extracts the second-level domain (SLD + TLD) from a URL.
/// Used for cookie isolation - all subdomains of the same second-level domain
/// will have their webviews mutually excluded.
/// Example: 'mail.google.com' -> 'google.com'
/// Example: 'api.github.com' -> 'github.com'
String getSecondLevelDomain(String url) {
  final host = extractDomain(url);
  final parts = host.split('.');
  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}.${parts.last}';
  }
  return host;
}

/// Domain aliases for treating different domains as equivalent for navigation.
/// Key is the alias domain, value is the canonical domain.
/// Used ONLY for nested webview URL blocking (not cookie isolation).
const Map<String, String> _domainAliases = {
  'mail.google.com': 'gmail.com',
  'inbox.google.com': 'gmail.com',
};

/// Normalizes a domain by applying aliases and extracting second-level domain.
/// Used for nested webview URL blocking - determines if navigation stays in same webview.
/// Example: 'mail.google.com' -> 'gmail.com' (alias)
/// Example: 'api.github.com' -> 'github.com' (second-level)
String getNormalizedDomain(String url) {
  final host = extractDomain(url);

  // Check if the full host has an alias
  if (_domainAliases.containsKey(host)) {
    return _domainAliases[host]!;
  }

  // Extract second-level domain
  final parts = host.split('.');
  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}.${parts.last}';
  }
  return host;
}

class WebViewModel {
  final String siteId; // Unique ID for per-site cookie isolation
  String initUrl; // Made non-final to allow URL editing
  String currentUrl;
  String name; // Custom name for the site
  String? pageTitle; // Current page title from webview
  List<Cookie> cookies;
  Widget? webview;
  WebViewController? controller;
  UserProxySettings proxySettings;
  bool javascriptEnabled;
  String userAgent;
  bool thirdPartyCookiesEnabled;
  bool incognito; // Private browsing mode - no cookies/cache persist

  String? defaultUserAgent;
  Function? stateSetterF;
  FindMatchesResult findMatches = FindMatchesResult();
  WebViewTheme _currentTheme = WebViewTheme.light;

  WebViewModel({
    String? siteId,
    required this.initUrl,
    String? currentUrl,
    String? name,
    this.cookies = const [],
    UserProxySettings? proxySettings,
    this.javascriptEnabled = true,
    this.userAgent = '',
    this.thirdPartyCookiesEnabled = false,
    this.incognito = false,
    this.stateSetterF,
  })  : siteId = siteId ?? _generateSiteId(),
        currentUrl = currentUrl ?? initUrl,
        name = name ?? extractDomain(initUrl),
        proxySettings = proxySettings ?? UserProxySettings(type: ProxyType.DEFAULT);

  void removeThirdPartyCookies(WebViewController controller) async {
    String script = '''
      (function() {
        function getDomain(hostname) {
          var parts = hostname.split('.');
          if (parts.length <= 2) {
            return hostname;
          }
          return parts.slice(parts.length - 2).join('.');
        }

        var currentDomain = getDomain(location.hostname);

        var cookies = document.cookie.split("; ");
        for (var i = 0; i < cookies.length; i++) {
          var cookie = cookies[i];
          var domain = cookie.match(/domain=[^;]+/);
          if (domain) {
            var domainValue = domain[0].split("=")[1];
            if (getDomain(domainValue) !== currentDomain) {
              var cookieName = cookie.split("=")[0];
              document.cookie = cookieName + "=; expires=Thu, 01 Jan 1970 00:00:00 UTC; path=/; domain=" + domainValue;
            }
          }
        }
      })();
    ''';

    await controller.evaluateJavascript(script);
  }

  Future<void> setController() async {
    if (controller == null) {
      return;
    }
    // Apply proxy settings first (before loading any URLs)
    await _applyProxySettings();
    
    await controller!.setOptions(
      javascriptEnabled: javascriptEnabled,
      userAgent: userAgent.isNotEmpty ? userAgent : null,
      thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
      incognito: incognito,
    );
    // Apply current theme preference
    await controller!.setThemePreference(_currentTheme);
    // Don't call loadUrl here - it's already initialized with the URL
    if (defaultUserAgent == null) {
      try {
        defaultUserAgent = await controller!.getDefaultUserAgent();
      } catch (e) {
        // Silently handle userAgent retrieval failure - this can happen during
        // testing or when webview isn't fully initialized
        defaultUserAgent = '';
      }
    }
  }

  /// Apply proxy settings to the webview
  Future<void> _applyProxySettings() async {
    final proxyManager = ProxyManager();
    try {
      await proxyManager.setProxySettings(proxySettings);
    } catch (e) {
      print('Failed to apply proxy settings: $e');
    }
  }

  /// Apply theme preference to the webview
  Future<void> setTheme(WebViewTheme theme) async {
    _currentTheme = theme;
    if (controller != null) {
      await controller!.setThemePreference(theme);
    }
  }

  /// Update proxy settings and apply them
  Future<void> updateProxySettings(UserProxySettings newSettings) async {
    proxySettings = newSettings;
    await _applyProxySettings();
  }

  Widget getWebView(
    Function(String url, {String? homeTitle}) launchUrlFunc,
    CookieManager cookieManager,
    Function saveFunc,
  ) {
    if (webview == null) {
      webview = WebViewFactory.createWebView(
        config: WebViewConfig(
          initialUrl: currentUrl,
          javascriptEnabled: javascriptEnabled,
          userAgent: userAgent.isNotEmpty ? userAgent : null,
          thirdPartyCookiesEnabled: thirdPartyCookiesEnabled,
          incognito: incognito,
          shouldOverrideUrlLoading: (url, shouldAllow) {
            // Use normalized domain comparison (handles aliases like mail.google.com -> gmail.com)
            final requestNormalized = getNormalizedDomain(url);
            final initialNormalized = getNormalizedDomain(initUrl);

            if (requestNormalized == initialNormalized) {
              return true; // Allow - same logical domain
            }

            // Open in nested webview with home site title
            launchUrlFunc(url, homeTitle: name);
            return false; // Cancel
          },
          onUrlChanged: (url) async {
            currentUrl = url;
            // Get page title and update name if we have a title
            if (controller != null) {
              var title = await controller!.getTitle();

              // Fallback: If controller doesn't provide title,
              // parse HTML to extract it
              if (title == null || title.isEmpty) {
                // Import getPageTitle from main.dart would cause circular dependency
                // So we'll handle this in the UI layer instead
              } else {
                pageTitle = title;
                // Auto-update name from page title if name is still the default domain
                if (name == extractDomain(initUrl)) {
                  name = title;
                }
              }

              // Reapply theme after page load (some sites might override it)
              await controller!.setThemePreference(_currentTheme);
            }
            await saveFunc();
          },
          onCookiesChanged: (newCookies) async {
            cookies = newCookies;
            if (!thirdPartyCookiesEnabled && controller != null) {
              removeThirdPartyCookies(controller!);
            }
          },
          onFindResult: (activeMatch, totalMatches) {
            findMatches.activeMatchOrdinal = activeMatch;
            findMatches.numberOfMatches = totalMatches;
            if (stateSetterF != null) {
              stateSetterF!();
            }
          },
        ),
        onControllerCreated: (ctrl) {
          controller = ctrl;
          setController();
        },
      );
    }
    return webview!;
  }

  WebViewController? getController(
    Function(String url, {String? homeTitle}) launchUrlFunc,
    CookieManager cookieManager,
    Function saveFunc,
  ) {
    if (webview == null) {
      webview = getWebView(launchUrlFunc, cookieManager, saveFunc);
    }
    if (controller != null) {
      setController();
    }
    return controller;
  }

  Future<void> deleteCookies(CookieManager cookieManager) async {
    for (final Cookie cookie in cookies) {
      await cookieManager.deleteCookie(
        url: Uri.parse(initUrl),
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? "/",
      );
    }
    cookies = [];
  }

  /// Capture current cookies from CookieManager and store locally.
  /// Used for per-site cookie isolation when switching between same-domain sites.
  Future<void> captureCookies(CookieManager cookieManager) async {
    if (incognito) return; // Don't capture cookies for incognito sites
    final url = Uri.parse(currentUrl.isNotEmpty ? currentUrl : initUrl);
    cookies = await cookieManager.getCookies(url: url);
  }

  /// Dispose the webview and controller to release resources.
  /// Used when unloading a site due to domain conflict.
  void disposeWebView() {
    webview = null;
    controller = null;
  }

  /// Get display name - uses the name field (which auto-updates from page title)
  String getDisplayName() {
    return name;
  }

  // Serialization methods
  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'initUrl': initUrl,
        'currentUrl': currentUrl,
        'name': name,
        'pageTitle': pageTitle,
        'cookies': cookies.map((cookie) => cookie.toJson()).toList(),
        'proxySettings': proxySettings.toJson(),
        'javascriptEnabled': javascriptEnabled,
        'userAgent': userAgent,
        'thirdPartyCookiesEnabled': thirdPartyCookiesEnabled,
        'incognito': incognito,
      };

  factory WebViewModel.fromJson(Map<String, dynamic> json, Function? stateSetterF) {
    return WebViewModel(
      siteId: json['siteId'], // May be null for legacy data, will auto-generate
      initUrl: json['initUrl'],
      currentUrl: json['currentUrl'],
      name: json['name'],
      cookies: (json['cookies'] as List<dynamic>)
          .map((dynamic e) => cookieFromJson(e))
          .toList(),
      proxySettings: UserProxySettings.fromJson(json['proxySettings']),
      javascriptEnabled: json['javascriptEnabled'],
      userAgent: json['userAgent'],
      thirdPartyCookiesEnabled: json['thirdPartyCookiesEnabled'],
      incognito: json['incognito'] ?? false,
      stateSetterF: stateSetterF,
    )..pageTitle = json['pageTitle'];
  }
}
