import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_leg_failure.dart';
import 'package:webspace/services/webview_tls.dart';

/// A load that failed on the way to the proxy is told apart from one that
/// failed at the site by Chromium's error name alone, since Android files
/// both under its proxy and TLS buckets.
void main() {
  test('names the proxy leg from the error Chromium reports', () {
    expect(ProxyLegFailure.of('net::ERR_PROXY_CONNECTION_FAILED'),
        ProxyLegFailure.unreachable);
    expect(ProxyLegFailure.of('net::ERR_TUNNEL_CONNECTION_FAILED'),
        ProxyLegFailure.tunnel);
    expect(ProxyLegFailure.of('net::ERR_SSL_PROTOCOL_ERROR'), isNull);
    expect(ProxyLegFailure.of('net::ERR_PROXY_CONNECTION_FAILED_X'), isNull);
    expect(ProxyLegFailure.of(''), isNull);
  });

  test('a tunnel the proxy did not open is not a certificate error (TLS-011)',
      () {
    // Android reports ERR_TUNNEL_CONNECTION_FAILED as FAILED_SSL_HANDSHAKE.
    // No certificate was shown, so a trust prompt for the site would ask the
    // user to vouch for a certificate that does not exist.
    expect(
      WebViewTls.isSslError(inapp.WebResourceError(
        type: inapp.WebResourceErrorType.FAILED_SSL_HANDSHAKE,
        description: 'net::ERR_TUNNEL_CONNECTION_FAILED',
      )),
      isFalse,
    );
    expect(
      WebViewTls.isSslError(inapp.WebResourceError(
        type: inapp.WebResourceErrorType.FAILED_SSL_HANDSHAKE,
        description: 'net::ERR_SSL_PROTOCOL_ERROR',
      )),
      isTrue,
    );
    expect(
      WebViewTls.isSslError(inapp.WebResourceError(
        type: inapp.WebResourceErrorType.SERVER_CERTIFICATE_UNTRUSTED,
        description: 'The certificate for this server is invalid.',
      )),
      isTrue,
    );
  });
}
