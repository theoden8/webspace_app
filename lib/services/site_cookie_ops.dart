import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';

/// Mutually-exclusive abstraction for per-site cookie operations.
///
/// `inapp.CookieManager.instance()` is a process-wide singleton. In
/// **legacy mode** (capture-nuke-restore) it targets the global
/// default jar — the only jar there is — so unscoped calls are
/// correct. In **profile mode** each WebView is bound to its own
/// [`WKWebsiteDataStore`](../../third_party/flutter_inappwebview_ios.patch)
/// or [`androidx.webkit.Profile`](../../third_party/flutter_inappwebview_android.patch);
/// to target a per-site jar, the call must pass
/// `webViewController:` so the patched plugin can route through that
/// WebView's bound profile.
///
/// `SiteCookieOps` is the seam: every per-site cookie operation goes
/// through this interface, and `_WebSpacePageState` picks one impl
/// once at startup based on `_useProfiles`. Call sites never branch
/// on profile mode; they call `cookieOps.deleteCookie(...)` and the
/// right thing happens. The two impls are by-design siblings — never
/// composed, never mixed — which mirrors the engine selection
/// (`ProfileIsolationEngine` vs `CookieIsolationEngine`).
///
/// The legacy `CookieIsolationEngine` continues to use
/// [`CookieManager`] directly, not via this interface. That engine
/// operates on the global jar by design (capture-nuke-restore moves
/// cookies in and out of the singleton); plumbing it through a
/// per-site abstraction would only obscure intent.
abstract class SiteCookieOps {
  /// Read the cookies the page at [url] can see in [siteId]'s jar.
  ///
  /// Both impls go through `inapp.CookieManager.instance().getCookies(...)`.
  /// Legacy passes no `webViewController:`, so the call hits the
  /// global default jar. Profile mode passes
  /// `webViewController: controller!.nativeController`; the patched
  /// plugin walks to that WebView's bound profile and reads from its
  /// `httpCookieStore` / per-profile `CookieManager` instead.
  ///
  /// HttpOnly cookies are returned in both modes (the native cookie
  /// store sees them, unlike `document.cookie`).
  Future<List<Cookie>> getCookies({
    WebViewController? controller,
    required String siteId,
    required Uri url,
  });

  /// Delete a cookie matching `(name, domain, path)` for [siteId].
  ///
  /// Same routing as [getCookies]: legacy hits the global default
  /// jar; profile mode hits the per-site profile via the patched
  /// plugin's `webViewController:` parameter.
  ///
  /// HttpOnly cookies are deletable in both modes (this calls into
  /// the native cookie store, not `document.cookie`).
  Future<void> deleteCookie({
    WebViewController? controller,
    required String siteId,
    required Uri url,
    required String name,
    String? domain,
    String? path,
  });
}

/// Per-site cookie ops backed by the global `inapp.CookieManager`.
/// Used when `_useProfiles == false`. `siteId` and `controller` are
/// ignored — there is only one jar.
class LegacySiteCookieOps implements SiteCookieOps {
  final CookieManager cookieManager;

  LegacySiteCookieOps(this.cookieManager);

  @override
  Future<List<Cookie>> getCookies({
    WebViewController? controller,
    required String siteId,
    required Uri url,
  }) async {
    return cookieManager.getCookies(url: url);
  }

  @override
  Future<void> deleteCookie({
    WebViewController? controller,
    required String siteId,
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) async {
    await cookieManager.deleteCookie(
      url: url,
      name: name,
      domain: domain,
      path: path ?? '/',
    );
  }
}

/// Per-site cookie ops that target the bound WebView's profile via
/// the **patched** `inapp.CookieManager`. Each call passes
/// `webViewController: controller!.nativeController`; the patched
/// plugin (see `third_party/flutter_inappwebview_*.patch`) walks to
/// the WebView's profile and routes the operation to its per-profile
/// cookie store.
///
/// This is what the previous JS-`document.cookie` workaround should
/// have been from the start: same surface, native fidelity (HttpOnly
/// included), no string-escape concerns, no main-thread JS hop per
/// delete.
class ProfileSiteCookieOps implements SiteCookieOps {
  final inapp.CookieManager _native = inapp.CookieManager.instance();

  @override
  Future<List<Cookie>> getCookies({
    WebViewController? controller,
    required String siteId,
    required Uri url,
  }) async {
    if (controller == null) return const [];
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
        'CookieOps',
        'getCookies($siteId, ${url.host}) failed: $e',
        level: LogLevel.error,
      );
      return const [];
    }
  }

  @override
  Future<void> deleteCookie({
    WebViewController? controller,
    required String siteId,
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) async {
    if (controller == null) {
      // No live WebView — typically the WebView was disposed before
      // the block rule fired. Nothing to delete; the cookie is gone
      // with the profile (or will be re-evaluated when the user
      // re-activates the site and the page sets the cookie again,
      // at which point onCookiesChanged fires and we land back here
      // with a live controller).
      return;
    }
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
        'CookieOps',
        'deleteCookie($name@${domain ?? url.host}, siteId=$siteId) '
            'failed: $e',
        level: LogLevel.error,
      );
    }
  }
}
