import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_controller.dart';

/// How the sites' cookies are kept apart, decided once per process by the
/// restore from the container probe. Each case holds what its engine works
/// with, so code that needs a container or the shared jar has it only where
/// it exists (BUG-007).
sealed class Isolation {
  /// The decision: containers where [native] reports them, [legacy]'s shared
  /// jar otherwise. False on Android System WebView without MULTI_PROFILE,
  /// iOS <17, macOS <14 and unsupported platforms.
  static Future<Isolation> probe({
    required ContainerNative native,
    required CookieIsolationEngine Function() legacy,
  }) async => await native.isSupported()
      ? Containers(engine: ContainerIsolationEngine(containerNative: native))
      : SharedJar(legacy());

  /// The cookies the page at [url] can see in its site's jar: [controller]'s
  /// container, or the shared jar. Fails with [CookieJarFailure].
  Future<List<Cookie>> cookiesAt(
    Uri url, {
    required WebViewController? controller,
  });

  /// Deletes one of the cookies [cookiesAt] reads.
  Future<void> deleteCookie(
    Cookie cookie, {
    required Uri url,
    required WebViewController? controller,
  });
}

/// Native per-site containers: each site's cookies, storage and cache in a
/// store of its own.
final class Containers implements Isolation {
  Containers({required this.engine});

  final ContainerIsolationEngine engine;

  /// Built on first use: building it reaches the plugin.
  late final ContainerCookieManager cookies = ContainerCookieManager();

  /// None without a webview: only the webview names its container, and the
  /// plain cookie manager reads the default store, no site's own.
  @override
  Future<List<Cookie>> cookiesAt(
    Uri url, {
    required WebViewController? controller,
  }) async => controller == null
      ? const []
      : cookies.getCookies(controller: controller, url: url);

  @override
  Future<void> deleteCookie(
    Cookie cookie, {
    required Uri url,
    required WebViewController? controller,
  }) => cookies.deleteCookie(
    controller: controller,
    url: url,
    name: cookie.name,
    domain: cookie.domain,
    path: cookie.path ?? '/',
  );
}

/// The legacy engine: one jar the sites' cookies take turns in.
final class SharedJar implements Isolation {
  SharedJar(this.jar);

  final CookieIsolationEngine jar;

  @override
  Future<List<Cookie>> cookiesAt(
    Uri url, {
    required WebViewController? controller,
  }) => jar.cookiesAt(url);

  @override
  Future<void> deleteCookie(
    Cookie cookie, {
    required Uri url,
    required WebViewController? controller,
  }) => jar.deleteCookie(cookie, url: url);
}
