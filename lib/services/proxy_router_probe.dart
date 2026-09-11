import 'dart:async';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webview.dart' show answerProxyRouterChallenge;

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
Future<void> runAttributionProbe(Map<String, String> siteIdToProbeUrl) async {
  for (final entry in siteIdToProbeUrl.entries) {
    await _probeOne(entry.key, entry.value);
  }
}

Future<void> _probeOne(String siteId, String probeUrl) async {
  final done = Completer<void>();
  void finish() {
    if (!done.isCompleted) done.complete();
  }

  final headless = inapp.HeadlessInAppWebView(
    initialUrlRequest: inapp.URLRequest(url: inapp.WebUri(probeUrl)),
    initialSettings: inapp.InAppWebViewSettings(
      // Bind to this site's container, so the probe travels the same
      // profile — and therefore the same proxy auth cache — its real
      // WebView will.
      containerId: 'ws-$siteId',
      javaScriptEnabled: false,
      transparentBackground: true,
    ),
    onReceivedHttpAuthRequest: (controller, challenge) =>
        answerProxyRouterChallenge(siteId, challenge),
    onLoadStop: (controller, url) => finish(),
    // An error still ends the probe: the relay either recorded the pair
    // before the failure or it did not, and "did not" is a failed check.
    onReceivedError: (controller, request, error) => finish(),
    onReceivedHttpError: (controller, request, response) => finish(),
  );

  try {
    await headless.run();
    await done.future.timeout(const Duration(seconds: 10), onTimeout: () {
      LogService.instance.log(
        'Proxy',
        'Attribution probe timed out for $siteId',
        level: LogLevel.error,
        sensitivity: LogSensitivity.sensitive,
      );
    });
  } catch (e) {
    LogService.instance.log(
      'Proxy',
      'Attribution probe error for $siteId: $e',
      level: LogLevel.error,
      sensitivity: LogSensitivity.sensitive,
    );
  } finally {
    await headless.dispose();
  }
}
