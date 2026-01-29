import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show WebUri;
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/proxy.dart';

String extractDomain(String url) {
  Uri uri = Uri.tryParse(url) ?? Uri();
  String? domain = uri.host;
  return domain.isEmpty ? url : domain;
}

class WebViewModel {
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
  })  : currentUrl = currentUrl ?? initUrl,
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
            String requestDomain = extractDomain(url);
            String initialDomain = extractDomain(initUrl);

            // Extract top-level and second-level domains
            List<String> requestDomainParts = requestDomain.split('.');
            List<String> initialDomainParts = initialDomain.split('.');

            // Compare top-level and second-level domains
            if (requestDomainParts.length >= 2 && initialDomainParts.length >= 2) {
              bool sameTopLevelDomain = requestDomainParts.last == initialDomainParts.last;
              bool sameSecondLevelDomain = requestDomainParts[requestDomainParts.length - 2] ==
                  initialDomainParts[initialDomainParts.length - 2];

              if (sameTopLevelDomain && sameSecondLevelDomain) {
                return true; // Allow
              }
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

  /// Get display name - uses the name field (which auto-updates from page title)
  String getDisplayName() {
    return name;
  }

  // Serialization methods
  Map<String, dynamic> toJson() => {
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
