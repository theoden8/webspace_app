import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'platform_info.dart';

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
    // webview_cef doesn't provide cookie reading API
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
    // webview_cef doesn't have cookie API
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
    // webview_cef doesn't have cookie API
  }

  /// Delete all cookies for a URL
  Future<void> deleteAllCookies({required Uri url}) async {
    if (PlatformInfo.useInAppWebView) {
      await _inApp.deleteCookies(url: _toWebUri(url));
    }
    // webview_cef doesn't have cookie API
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
