import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart';

/// Mutually-exclusive abstraction for per-site cookie operations.
///
/// `inapp.CookieManager.instance()` is a process-wide singleton that
/// only ever sees the **default** profile's cookie jar. In legacy
/// (capture-nuke-restore) mode that's the only jar there is, so
/// targeting it is correct. In profile mode each WebView is bound to
/// its own [`WKWebsiteDataStore`](../../third_party/flutter_inappwebview_ios/PATCHES.md)
/// or [`androidx.webkit.Profile`](../../third_party/flutter_inappwebview_android/PATCHES.md)
/// — invisible to the global manager — and a global-jar delete
/// silently misses, breaking ISO-011 (per-site cookie blocking).
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
  /// Read the cookies visible to the page at [url] in [siteId]'s
  /// jar. In legacy mode this routes through the global
  /// `CookieManager.getCookies(url:)`. In profile mode it
  /// JS-evaluates `document.cookie` inside the bound WebView and
  /// parses the `name=value; ...` form into [Cookie] objects.
  ///
  /// Caveat in profile mode: `document.cookie` returns only
  /// non-HttpOnly cookies; HttpOnly cookies (typical session
  /// tokens) are visible to neither read nor write here. The
  /// per-site profile is the source of truth — these reads reflect
  /// what the page itself can see.
  Future<List<Cookie>> getCookies({
    WebViewController? controller,
    required String siteId,
    required Uri url,
  });

  /// Delete a cookie matching `(name, domain, path)` for [siteId].
  ///
  /// In legacy mode, [controller] and [siteId] are ignored; the
  /// delete routes through the global `CookieManager`.
  ///
  /// In profile mode, the delete runs as a `document.cookie =
  /// '<name>=; expires=Thu, 01 Jan 1970 …; path=…; domain=…';`
  /// JS write inside the bound WebView, which executes in the
  /// per-site profile context. Caveat: JS cannot delete HttpOnly
  /// cookies; tracking cookies (the typical cookie-blocking target)
  /// are JS-readable so this matches user expectations in practice.
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
/// JS evaluation. Used when `_useProfiles == true`.
///
/// We intentionally do NOT route through `inapp.CookieManager`'s
/// `webViewController:` parameter (which on iOS scopes operations to
/// a WebView's data store) because Android's CookieManager is
/// unconditionally global; using JS uniformly across platforms
/// keeps the behaviour identical.
class ProfileSiteCookieOps implements SiteCookieOps {
  @override
  Future<List<Cookie>> getCookies({
    WebViewController? controller,
    required String siteId,
    required Uri url,
  }) async {
    if (controller == null) return const [];
    // `document.cookie` returns the cookies the document can read —
    // i.e. the per-profile non-HttpOnly cookies for the current
    // origin. Format: `name1=value1; name2=value2; …`. We parse it
    // and synthesize Cookie objects with name + value populated and
    // host/path inferred from the request URL. Domain/expires/secure
    // attributes are not exposed by `document.cookie` and stay null.
    final raw = await controller.evaluateJavascriptReturning(
      "document.cookie",
    );
    if (raw == null) return const [];
    final str = raw.toString();
    if (str.isEmpty) return const [];

    final out = <Cookie>[];
    for (final piece in str.split(';')) {
      final trimmed = piece.trim();
      if (trimmed.isEmpty) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      out.add(Cookie(
        name: trimmed.substring(0, eq),
        value: trimmed.substring(eq + 1),
        domain: url.host,
        path: '/',
      ));
    }
    return out;
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
    final pathClause = "; path=${path ?? '/'}";
    // `domain=` is only emitted when the cookie was set with a
    // Domain attribute (cookie.domain != null/empty). For host-only
    // cookies, omitting Domain makes the JS write target the same
    // host the document is on, which matches the original cookie's
    // scope.
    final domainClause = (domain != null && domain.isNotEmpty)
        ? "; domain=$domain"
        : '';
    final js = "document.cookie = '"
        "${_escape(name)}=; expires=Thu, 01 Jan 1970 00:00:00 UTC"
        "$pathClause$domainClause"
        "';";
    try {
      await controller.evaluateJavascript(js);
    } catch (e) {
      LogService.instance.log(
        'CookieOps',
        'JS delete failed for ${name}@${domain ?? url.host} '
            '(siteId=$siteId): $e',
        level: LogLevel.error,
      );
    }
  }

  /// Backslash-escape single quotes so the JS string literal stays
  /// well-formed for cookie names like `foo'bar`. Cookie names per
  /// RFC 6265 are tokens that should never contain quotes, but
  /// defending against malformed input here is cheap.
  static String _escape(String s) => s.replaceAll(r"\", r"\\").replaceAll("'", r"\'");
}
