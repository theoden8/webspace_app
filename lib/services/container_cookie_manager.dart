import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_controller.dart';

/// Per-site cookie operations that target the bound WebView's container
/// via the WebSpace fork's `inapp.CookieManager`.
///
/// Sibling of [`CookieManager`](webview.dart), never composed or mixed:
/// only an `Isolation` of `Containers` holds one, and each call passes
/// `webViewController:` so the WebSpace fork of `flutter_inappwebview`
/// walks to the WebView's bound container and routes the operation to its
/// per-container cookie store. HttpOnly cookies are deletable too;
/// `getCookies` returns full attributes
/// (domain/path/expiresDate/isSecure/isHttpOnly).
class ContainerCookieManager {
  /// Read the cookies the page at [url] can see in the jar of the container
  /// [controller]'s webview is bound to. Fails with [CookieJarFailure]: a
  /// read that failed is not an empty jar.
  Future<List<Cookie>> getCookies({
    required WebViewController controller,
    required Uri url,
  }) async {
    final raw = await cookieChannel((plugin) => plugin.getCookies(
          url: inapp.WebUri(url.toString()),
          webViewController: controller.nativeController,
        ));
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
  }

  /// Delete a cookie matching `(name, domain, path)` from the jar of the
  /// container [controller]'s webview is bound to. Fails with
  /// [CookieJarFailure].
  ///
  /// When [controller] is null, the WebView has been disposed before
  /// the delete reached us; the call no-ops (the cookie either went
  /// with the profile or will be re-evaluated when the user
  /// re-activates the site).
  Future<void> deleteCookie({
    WebViewController? controller,
    required Uri url,
    required String name,
    String? domain,
    String? path,
  }) async {
    if (controller == null) return;
    await cookieChannel((plugin) => plugin.deleteCookie(
          url: inapp.WebUri(url.toString()),
          name: name,
          domain: domain ?? '',
          path: path ?? '/',
          webViewController: controller.nativeController,
        ));
  }
}
