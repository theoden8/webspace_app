import 'dart:math';

import 'package:flutter/foundation.dart';
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

/// Common multi-part TLDs (country-code second-level domains)
/// These need special handling because the TLD is effectively two parts (e.g., .co.uk)
const Set<String> _multiPartTlds = {
  'co.uk', 'org.uk', 'me.uk', 'ac.uk', 'gov.uk',
  'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.nz', 'net.nz', 'org.nz', 'govt.nz',
  'co.jp', 'ne.jp', 'or.jp', 'ac.jp', 'go.jp',
  'com.br', 'net.br', 'org.br', 'gov.br',
  'co.in', 'net.in', 'org.in', 'gov.in',
  'com.mx', 'org.mx', 'gob.mx',
  'co.za', 'org.za', 'gov.za',
  'com.sg', 'org.sg', 'gov.sg', 'edu.sg',
  'co.kr', 'or.kr', 'go.kr',
  'com.cn', 'net.cn', 'org.cn', 'gov.cn',
  'com.tw', 'org.tw', 'gov.tw',
  'com.hk', 'org.hk', 'gov.hk',
  'co.id', 'or.id', 'go.id',
  'com.ph', 'org.ph', 'gov.ph',
  'co.th', 'or.th', 'go.th',
  'com.vn', 'gov.vn',
  'com.my', 'org.my', 'gov.my',
  'co.il', 'org.il', 'gov.il',
  'com.tr', 'org.tr', 'gov.tr',
  'com.pl', 'org.pl', 'gov.pl',
  'co.de', 'com.de',
  'com.fr', 'org.fr', 'gouv.fr',
  'co.it', 'org.it', 'gov.it',
  'co.es', 'org.es', 'gob.es',
  'co.nl', 'org.nl',
  'com.ar', 'org.ar', 'gov.ar',
  'com.ru', 'org.ru', 'gov.ru',
};

/// Extracts the second-level domain (SLD + TLD) from a URL.
/// Used for cookie isolation - all subdomains of the same second-level domain
/// will have their webviews mutually excluded.
/// Handles multi-part TLDs like .co.uk, .com.au, etc.
/// Example: 'mail.google.com' -> 'google.com'
/// Example: 'api.github.com' -> 'github.com'
/// Example: 'www.google.co.uk' -> 'google.co.uk'
String getSecondLevelDomain(String url) {
  final host = extractDomain(url);
  final parts = host.split('.');

  if (parts.length >= 3) {
    // Check if the last two parts form a multi-part TLD
    final possibleTld = '${parts[parts.length - 2]}.${parts.last}';
    if (_multiPartTlds.contains(possibleTld)) {
      // Return third-to-last part + multi-part TLD (e.g., google.co.uk)
      return '${parts[parts.length - 3]}.$possibleTld';
    }
  }

  if (parts.length >= 2) {
    return '${parts[parts.length - 2]}.${parts.last}';
  }
  return host;
}

/// Domain aliases for treating different domains as equivalent for navigation.
/// Key is the alias domain, value is the canonical domain.
/// Used ONLY for nested webview URL blocking (not cookie isolation).
/// All Google properties (gmail.com, regional domains, etc.) are treated as google.com.
const Map<String, String> _domainAliases = {
  'gmail.com': 'google.com',
  // Regional Google domains
  'google.co.uk': 'google.com',
  'google.com.au': 'google.com',
  'google.co.jp': 'google.com',
  'google.co.in': 'google.com',
  'google.de': 'google.com',
  'google.fr': 'google.com',
  'google.es': 'google.com',
  'google.it': 'google.com',
  'google.nl': 'google.com',
  'google.pl': 'google.com',
  'google.ru': 'google.com',
  'google.com.br': 'google.com',
  'google.com.mx': 'google.com',
  'google.ca': 'google.com',
  'google.co.kr': 'google.com',
  'google.com.tw': 'google.com',
  'google.com.hk': 'google.com',
  'google.co.id': 'google.com',
  'google.co.th': 'google.com',
  'google.com.vn': 'google.com',
  'google.com.ph': 'google.com',
  'google.com.my': 'google.com',
  'google.com.sg': 'google.com',
  'google.co.nz': 'google.com',
  'google.co.za': 'google.com',
  'google.com.ar': 'google.com',
  'google.cl': 'google.com',
  'google.com.co': 'google.com',
  'google.com.tr': 'google.com',
  'google.co.il': 'google.com',
  'google.ae': 'google.com',
  'google.com.sa': 'google.com',
  'google.com.eg': 'google.com',
  'google.com.pk': 'google.com',
  'google.com.ng': 'google.com',
  'google.be': 'google.com',
  'google.at': 'google.com',
  'google.ch': 'google.com',
  'google.se': 'google.com',
  'google.no': 'google.com',
  'google.dk': 'google.com',
  'google.fi': 'google.com',
  'google.ie': 'google.com',
  'google.pt': 'google.com',
  'google.cz': 'google.com',
  'google.ro': 'google.com',
  'google.hu': 'google.com',
  'google.gr': 'google.com',
};

/// Normalizes a domain by applying aliases and extracting second-level domain.
/// Used for nested webview URL blocking - determines if navigation stays in same webview.
/// Handles multi-part TLDs like .co.uk, .com.au, etc.
/// Example: 'mail.google.com' -> 'google.com' (second-level)
/// Example: 'gmail.com' -> 'google.com' (alias)
/// Example: 'www.google.co.uk' -> 'google.com' (second-level extracted, then aliased)
String getNormalizedDomain(String url) {
  final host = extractDomain(url);

  // Check if the full host has an alias
  if (_domainAliases.containsKey(host)) {
    return _domainAliases[host]!;
  }

  // Extract second-level domain
  final secondLevel = getSecondLevelDomain(url);

  // Check if the second-level domain has an alias
  if (_domainAliases.containsKey(secondLevel)) {
    return _domainAliases[secondLevel]!;
  }

  return secondLevel;
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
              if (kDebugMode) {
                debugPrint('[WebView] "$name" navigating within domain: $url');
              }
              return true; // Allow - same logical domain
            }

            // Open in nested webview with home site title
            if (kDebugMode) {
              debugPrint('[WebView] "$name" opening nested: $url');
              debugPrint('  from: $initialNormalized -> to: $requestNormalized');
            }
            launchUrlFunc(url, homeTitle: name);
            return false; // Cancel
          },
          onUrlChanged: (url) async {
            currentUrl = url;
            // Trigger UI rebuild so URL bar updates
            if (stateSetterF != null) {
              stateSetterF!();
            }
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
