import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'platform_info.dart';
import 'package:webspace/settings/proxy.dart';

// Helper to convert Uri to WebUri
inapp.WebUri _toWebUri(Uri uri) => inapp.WebUri(uri.toString());

/// Unified cookie representation across platforms
class UnifiedCookie {
  final String name;
  final String value;
  final String? domain;
  final String? path;
  final int? expiresDate;
  final bool? isSecure;
  final bool? isHttpOnly;
  final bool? isSessionOnly;
  final String? sameSite;

  UnifiedCookie({
    required this.name,
    required this.value,
    this.domain,
    this.path,
    this.expiresDate,
    this.isSecure,
    this.isHttpOnly,
    this.isSessionOnly,
    this.sameSite,
  });

  /// Convert from flutter_inappwebview Cookie
  factory UnifiedCookie.fromInAppCookie(inapp.Cookie cookie) {
    return UnifiedCookie(
      name: cookie.name,
      value: cookie.value,
      domain: cookie.domain,
      path: cookie.path,
      expiresDate: cookie.expiresDate,
      isSecure: cookie.isSecure,
      isHttpOnly: cookie.isHttpOnly,
      isSessionOnly: cookie.isSessionOnly,
      sameSite: cookie.sameSite?.toString(),
    );
  }

  /// Convert to flutter_inappwebview Cookie
  inapp.Cookie toInAppCookie() {
    return inapp.Cookie(
      name: name,
      value: value,
      domain: domain,
      path: path,
      expiresDate: expiresDate,
      isSecure: isSecure,
      isHttpOnly: isHttpOnly,
      isSessionOnly: isSessionOnly,
      sameSite: sameSite != null ? inapp.HTTPCookieSameSitePolicy.values.firstWhere(
        (e) => e.toString() == sameSite,
        orElse: () => inapp.HTTPCookieSameSitePolicy.LAX,
      ) : null,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() => {
    'name': name,
    'value': value,
    'domain': domain,
    'path': path,
    'expiresDate': expiresDate,
    'isSecure': isSecure,
    'isHttpOnly': isHttpOnly,
    'isSessionOnly': isSessionOnly,
    'sameSite': sameSite,
  };

  /// Deserialize from JSON
  factory UnifiedCookie.fromJson(Map<String, dynamic> json) {
    return UnifiedCookie(
      name: json['name'],
      value: json['value'],
      domain: json['domain'],
      path: json['path'],
      expiresDate: json['expiresDate'],
      isSecure: json['isSecure'],
      isHttpOnly: json['isHttpOnly'],
      isSessionOnly: json['isSessionOnly'],
      sameSite: json['sameSite'],
    );
  }
}

/// Unified cookie manager that works across platforms
class UnifiedCookieManager {
  static final UnifiedCookieManager _instance = UnifiedCookieManager._internal();
  factory UnifiedCookieManager() => _instance;
  UnifiedCookieManager._internal();

  inapp.CookieManager? _inAppManager;

  inapp.CookieManager get _inApp {
    _inAppManager ??= inapp.CookieManager.instance();
    return _inAppManager!;
  }

  /// Get cookies for a URL
  Future<List<UnifiedCookie>> getCookies({required Uri url}) async {
    if (PlatformInfo.useInAppWebView) {
      final cookies = await _inApp.getCookies(url: _toWebUri(url));
      return cookies.map((c) => UnifiedCookie.fromInAppCookie(c)).toList();
    }
    return [];
  }

  /// Set a cookie
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
    if (PlatformInfo.useInAppWebView) {
      await _inApp.setCookie(
        url: _toWebUri(url),
        name: name,
        value: value,
        domain: domain,
        path: path ?? '/',
        expiresDate: expiresDate,
        isSecure: isSecure,
        isHttpOnly: isHttpOnly,
      );
    }
  }

  /// Delete a cookie
  Future<void> deleteCookie({
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) async {
    if (PlatformInfo.useInAppWebView) {
      await _inApp.deleteCookie(
        url: _toWebUri(url),
        name: name,
        domain: domain,
        path: path ?? '/',
      );
    }
  }

  /// Delete all cookies for a URL
  Future<void> deleteAllCookies({required Uri url}) async {
    if (PlatformInfo.useInAppWebView) {
      await _inApp.deleteCookies(url: _toWebUri(url));
    }
  }
}

/// Find matches result (unified across platforms)
class UnifiedFindMatchesResult {
  int activeMatchOrdinal = 0;
  int numberOfMatches = 0;

  UnifiedFindMatchesResult();
}

/// Theme preference for webviews
enum WebViewTheme {
  light,
  dark,
  system,
}

/// Unified proxy manager that works across platforms
class UnifiedProxyManager {
  static final UnifiedProxyManager _instance = UnifiedProxyManager._internal();
  factory UnifiedProxyManager() => _instance;
  UnifiedProxyManager._internal();

  /// Set proxy settings for InAppWebView (Android/iOS)
  Future<void> setProxySettings(UserProxySettings proxySettings) async {
    if (!PlatformInfo.isProxySupported) {
      // Proxy only supported on InAppWebView
      return;
    }

    try {
      final proxyController = inapp.ProxyController.instance();
      
      if (proxySettings.type == ProxyType.DEFAULT) {
        // Clear proxy settings - use system default
        await proxyController.clearProxyOverride();
      } else {
        // Set proxy override
        if (proxySettings.address == null || proxySettings.address!.isEmpty) {
          throw Exception('Proxy address is required for non-default proxy type');
        }

        // Parse address and port
        final addressParts = proxySettings.address!.split(':');
        if (addressParts.length != 2) {
          throw Exception('Proxy address must be in format host:port');
        }

        final host = addressParts[0];
        final port = int.tryParse(addressParts[1]);
        if (port == null) {
          throw Exception('Invalid port number in proxy address');
        }

        // Convert ProxyType to ProxyScheme
        String scheme;
        switch (proxySettings.type) {
          case ProxyType.HTTP:
            scheme = 'http';
            break;
          case ProxyType.HTTPS:
            scheme = 'https';
            break;
          case ProxyType.SOCKS5:
            scheme = 'socks5';
            break;
          default:
            scheme = 'http';
        }

        // Set proxy override
        await proxyController.setProxyOverride(
          settings: inapp.ProxySettings(
            proxyRules: [
              inapp.ProxyRule(
                url: '$scheme://$host:$port',
              ),
            ],
            bypassRules: ['<local>'], // Bypass localhost
          ),
        );
      }
    } catch (e) {
      print('Error setting proxy: $e');
      rethrow;
    }
  }

  /// Clear proxy settings
  Future<void> clearProxy() async {
    if (!PlatformInfo.isProxySupported) {
      return;
    }

    try {
      final proxyController = inapp.ProxyController.instance();
      await proxyController.clearProxyOverride();
    } catch (e) {
      print('Error clearing proxy: $e');
    }
  }
}
