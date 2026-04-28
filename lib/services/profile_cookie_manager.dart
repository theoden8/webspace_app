import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';

/// Per-site cookie operations that target the bound WebView's profile
/// via the **patched** `inapp.CookieManager`.
///
/// Sibling of [`CookieManager`](webview.dart) — never composed, never
/// mixed. `_WebSpacePageState` instantiates exactly one based on
/// `_useProfiles`:
///
///   - `_useProfiles == false`: `CookieManager` (global default jar)
///     drives every per-site cookie op. The legacy
///     `CookieIsolationEngine` capture-nuke-restore cycle uses the
///     same instance.
///   - `_useProfiles == true`: `ProfileCookieManager` is created;
///     each call passes `webViewController:` so the patched plugin
///     (see `third_party/flutter_inappwebview_*.patch`) walks to the
///     WebView's bound profile and routes the operation to its
///     per-profile cookie store. HttpOnly cookies are deletable too;
///     `getCookies` returns full attributes
///     (domain/path/expiresDate/isSecure/isHttpOnly).
///
/// There is intentionally no shared base class — call sites branch
/// explicitly on which manager is non-null. With only two real impls
/// and one of them being the existing thin `CookieManager` wrapper
/// over `inapp.CookieManager.instance()`, an interface here would be
/// indirection without payoff.
class ProfileCookieManager {
  final inapp.CookieManager _native = inapp.CookieManager.instance();

  /// Read the cookies the page at [url] can see in [siteId]'s jar.
  /// Returns an empty list (and logs the failure) on a runtime error
  /// from the platform side.
  Future<List<Cookie>> getCookies({
    required WebViewController controller,
    required String siteId,
    required Uri url,
  }) async {
    try {
      final raw = await _native.getCookies(
        url: inapp.WebUri(url.toString()),
        webViewController: controller.nativeController,
      );
      return raw
          .map((c) => Cookie(
                name: c.name,
                value: c.value,
                domain: c.domain,
                path: c.path,
                expiresDate: c.expiresDate,
                isSecure: c.isSecure,
                isHttpOnly: c.isHttpOnly,
              ))
          .toList(growable: false);
    } catch (e) {
      LogService.instance.log(
        'ProfileCookieManager',
        'getCookies($siteId, ${url.host}) failed: $e',
        level: LogLevel.error,
      );
      return const [];
    }
  }

  /// Delete a cookie matching `(name, domain, path)` for [siteId].
  ///
  /// When [controller] is null, the WebView has been disposed before
  /// the delete reached us; the call no-ops (the cookie either went
  /// with the profile or will be re-evaluated when the user
  /// re-activates the site).
  Future<void> deleteCookie({
    WebViewController? controller,
    required String siteId,
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) async {
    if (controller == null) return;
    try {
      await _native.deleteCookie(
        url: inapp.WebUri(url.toString()),
        name: name,
        domain: domain ?? '',
        path: path ?? '/',
        webViewController: controller.nativeController,
      );
    } catch (e) {
      LogService.instance.log(
        'ProfileCookieManager',
        'deleteCookie($name@${domain ?? url.host}, siteId=$siteId) '
            'failed: $e',
        level: LogLevel.error,
      );
    }
  }
}
