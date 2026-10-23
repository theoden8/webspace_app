import 'dart:async';
import 'dart:math' show min;
import 'package:webspace/services/container_names.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:flutter/services.dart'
    show MissingPluginException, PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/webview.dart' show WebViewFactory;
import 'package:webspace/services/webview_proxy.dart'
    show ProxyManager, answerProxyRouterChallenge, routerRelayProxyFor;

/// How many containers are probed at once. Each probe is a headless
/// WebView, so a launch with many sites must not build one per site at the
/// same moment; one at a time would make the launch wait one probe per
/// site instead of about one.
const int probeConcurrency = 4;

/// The real attribution probe (PROXY-015).
///
/// Drives each site's container to fetch a unique probe host so the relay
/// can record which credential that container actually presents. The
/// service compares the pairs; a mismatch means this device does not give
/// each container its own proxy credential and router mode is refused.
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
Future<void> runAttributionProbe(Map<SiteId, String> siteIdToProbeUrl) async {
  final entries = siteIdToProbeUrl.entries.toList();
  var next = 0;
  Future<void> worker() async {
    while (next < entries.length) {
      final entry = entries[next++];
      await _probeOne(entry.key, probeUrl: entry.value);
    }
  }

  await Future.wait([
    for (var i = 0; i < min(probeConcurrency, entries.length); i++) worker(),
  ]);
}

Future<void> _probeOne(SiteId siteId, {required String probeUrl}) async {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  final containerId = ContainerName.of(ContainerKey.ofSite(siteId));
  // Apple has no process-wide rule to carry the probe, so the headless view
  // names the relay itself with this site's credential -- the same thing its
  // real WebView does. Null on Android, where the override already covers it.
  final proxy = routerRelayProxyFor(siteId: siteId, ownsContainer: true);
  ProxyManager.noteStoreProxy(containerId, proxy: proxy);
  final headless = inapp.HeadlessInAppWebView(
    initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(probeUrl)),
    initialSettings: inapp.InAppWebViewSettings(
      // Bind to this site's container, so the probe travels the same
      // profile — and therefore the same proxy auth cache — its real
      // WebView will.
      containerId: containerId,
      proxySettings: proxy,
      javaScriptEnabled: false,
      transparentBackground: true,
      useHybridComposition: WebViewFactory.hybridComposition,
    ),
    onReceivedHttpAuthRequest: (controller, challenge) =>
        answerProxyRouterChallenge(RouterIdentity.ofSite(siteId),
            challenge: challenge),
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
          'Attribution probe timed out for $siteId', sensitive: true);
    });
  } on PlatformException catch (e) {
    LogTag.proxy.error(
        'Attribution probe error for $siteId: $e', sensitive: true);
  } on MissingPluginException catch (e) {
    LogTag.proxy.error(
        'Attribution probe error for $siteId: $e', sensitive: true);
  } finally {
    await headless.dispose();
  }
}
