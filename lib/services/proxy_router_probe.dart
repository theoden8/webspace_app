import 'dart:async';
import 'package:webspace/services/container_names.dart';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/webview.dart' show WebViewFactory;
import 'package:webspace/services/webview_proxy.dart'
    show ProxyManager, answerProxyRouterChallenge, routerRelayProxyOf;

/// The real attribution probe (PROXY-015).
///
/// Drives the profile [identity] runs in to fetch [url], a unique probe
/// host, so the relay can record which credential that profile actually
/// presents: a site's own container, or the default profile for the
/// identity every site without one shares. [RouterAttribution] compares the
/// pairs; a mismatch means this device does not give each profile its own
/// proxy credential.
///
/// A headless WebView rather than an injected `fetch` into the live page,
/// for two reasons. A page's own `connect-src` / `img-src` CSP can block
/// an injected request, which would read as "attribution broken" when
/// nothing is broken. And a site need not be loaded at all when the check
/// runs. The headless view loads only our probe URL, so no site content
/// is involved.
///
/// The probe cannot leak: the relay answers probe hosts itself and never
/// opens an upstream, and `.invalid` is RFC 2606 reserved so the name
/// cannot resolve even if something did forward it.
///
/// Fails with the webview plugin's [PlatformException] or
/// [MissingPluginException] when a headless view cannot be torn down.
Future<void> runAttributionProbe(
  RouterIdentity identity, {
  required String url,
}) async {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  final containerId = switch (identity.site) {
    final site? => ContainerName.of(ContainerKey.ofSite(site)),
    null => null,
  };
  // Apple has no process-wide rule to carry the probe, so the headless view
  // names the relay itself with this identity's credential -- the same
  // thing its real WebViews do. Null on Android, where the override already
  // covers it.
  final proxy = routerRelayProxyOf(identity);
  ProxyManager.noteStoreProxy(containerId, proxy: proxy);
  final headless = inapp.HeadlessInAppWebView(
    initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(url)),
    initialSettings: inapp.InAppWebViewSettings(
      // Bind to this identity's profile, so the probe travels the same
      // proxy auth cache its real WebViews will.
      containerId: containerId,
      proxySettings: proxy,
      javaScriptEnabled: false,
      transparentBackground: true,
      useHybridComposition: WebViewFactory.hybridComposition,
    ),
    // Answered at once, not through the funnel: the funnel waits for this
    // very check.
    onReceivedHttpAuthRequest: (controller, challenge) =>
        answerProxyRouterChallenge(identity, challenge: challenge),
    onLoadStop: (controller, url) => finish(),
    // An error still ends the probe: the relay either recorded the pair
    // before the failure or it did not, and "did not" is a failed check.
    onReceivedError: (controller, request, error) => finish(),
    onReceivedHttpError: (controller, request, response) => finish(),
  );

  try {
    await headless.run();
    await done.future.timeout(const Duration(seconds: 10), onTimeout: () {
      LogTag.proxy.error(
          'Attribution probe timed out for $identity', sensitive: true);
    });
  } on PlatformException catch (e) {
    LogTag.proxy.error(
        'Attribution probe error for $identity: $e', sensitive: true);
  } on MissingPluginException catch (e) {
    LogTag.proxy.error(
        'Attribution probe error for $identity: $e', sensitive: true);
  } finally {
    await headless.dispose();
  }
}
