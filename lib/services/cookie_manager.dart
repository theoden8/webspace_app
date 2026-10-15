import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/log_service.dart';

typedef Cookie = inapp.Cookie;

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

/// [cookieFromJson] for stored JSON: null, rather than a cast failure, unless
/// every field has the type the cookie takes.
Cookie? tryCookieFromJson(Object? json) {
  if (json is! Map<String, dynamic>) return null;
  if (json['name'] is! String ||
      json['domain'] is! String? ||
      json['path'] is! String? ||
      json['expiresDate'] is! int? ||
      json['isSecure'] is! bool? ||
      json['isHttpOnly'] is! bool? ||
      json['isSessionOnly'] is! bool? ||
      json['sameSite'] is! String?) {
    return null;
  }
  return cookieFromJson(json);
}

/// What a cookie call throws when the plugin's cookie channel fails: the
/// native side answered with an error, or this engine has no handler for the
/// channel. A read that failed returned nothing; it is not an empty jar.
final class CookieJarFailure implements Exception {
  const CookieJarFailure(this.message);

  /// The platform's report, as its exception printed it.
  final String message;

  @override
  String toString() => 'CookieJarFailure: $message';
}

/// The plugin's cookie manager, which only [cookieChannel] hands out.
final inapp.CookieManager _plugin = inapp.CookieManager.instance();

/// Runs [call], one call on the plugin's cookie channel, with what the channel
/// throws named once: every cookie op in the app comes through here.
Future<T> cookieChannel<T>(
    Future<T> Function(inapp.CookieManager plugin) call) async {
  try {
    return await call(_plugin);
  } on PlatformException catch (e, stack) {
    // An error envelope (MethodChannel.invokeMethod), e.g. what Android's
    // MyCookieManager rethrows from CookieManager.getInstance().
    Error.throwWithStackTrace(CookieJarFailure('$e'), stack);
  } on MissingPluginException catch (e, stack) {
    // No handler in this engine, or a method the platform does not implement.
    Error.throwWithStackTrace(CookieJarFailure('$e'), stack);
  }
}

/// The shared jar the legacy engine's sites use. Every call fails only with
/// [CookieJarFailure].
class CookieManager {
  Future<List<Cookie>> getCookies({required Uri url}) => cookieChannel(
      (plugin) => plugin.getCookies(url: inapp.WebUri(url.toString())));

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
  /// One URL's read failing fails the whole capture, so part of the jar is
  /// never returned as all of it.
  Future<List<Cookie>> getAllCookies({List<Uri>? candidateUrls}) async {
    if (hostIsIOS || hostIsMacOS) {
      return cookieChannel((plugin) => plugin.getAllCookies());
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
    await cookieChannel((plugin) => plugin.setCookie(
          url: inapp.WebUri(url.toString()),
          name: name,
          value: value,
          domain: domain,
          path: path ?? '/',
          expiresDate: expiresDate,
          isSecure: isSecure,
          isHttpOnly: isHttpOnly,
        ));
  }

  Future<void> deleteCookie({
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) =>
      cookieChannel((plugin) => plugin.deleteCookie(
            url: inapp.WebUri(url.toString()),
            name: name,
            domain: domain,
            path: path ?? '/',
          ));

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

  /// Used for aggressive cookie isolation when switching between same-domain sites.
  Future<void> deleteAllCookies() async {
    await cookieChannel((plugin) => plugin.deleteAllCookies());
  }

  /// Commit pending cookie writes to persistent storage.
  ///
  /// Android only: the fork implements `flush` there (fanning out across every
  /// container's jar, not just the default one), and the platform interface's
  /// default throws `UnimplementedError` everywhere else. Callers gate on
  /// [flushSupported] rather than calling and catching, so an unsupported
  /// platform costs no channel round-trip. A failure is logged and dropped: a
  /// flush is an optimization over the platform's own lazy commit, never a
  /// correctness requirement.
  static bool get flushSupported => hostIsAndroid;

  Future<void> flush() async {
    if (!flushSupported) return;
    try {
      await cookieChannel((plugin) => plugin.flush());
    } on CookieJarFailure catch (e) {
      LogTag.cookieManager.warning('flush() failed: $e');
    }
  }
}
