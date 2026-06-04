import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';

void main() {
  group('TLS-010 loopback sinkhole cert classification', () {
    test('localhost cert for a remote host is a sinkhole', () {
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: 'htlb.casalemedia.com',
          issuedToCName: 'localhost',
          issuedByCName: 'localhost',
        ),
        isTrue,
      );
    });

    test('only issuer is localhost still counts', () {
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: 'fastlane.rubiconproject.com',
          issuedToCName: 'ads.example.com',
          issuedByCName: 'localhost',
        ),
        isTrue,
      );
    });

    test('case and whitespace are normalized', () {
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: 'tracker.example.com',
          issuedToCName: '  LocalHost ',
          issuedByCName: null,
        ),
        isTrue,
      );
    });

    test('genuine https://localhost dev server is not suppressed', () {
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: 'localhost',
          issuedToCName: 'localhost',
          issuedByCName: 'localhost',
        ),
        isFalse,
      );
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: '127.0.0.1',
          issuedToCName: 'localhost',
          issuedByCName: 'localhost',
        ),
        isFalse,
      );
    });

    test('ordinary self-signed cert with a real CN still prompts', () {
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: 'self-signed.example.com',
          issuedToCName: 'self-signed.example.com',
          issuedByCName: 'My Homelab CA',
        ),
        isFalse,
      );
    });

    test('missing CNames are not a sinkhole', () {
      expect(
        WebViewFactory.isLoopbackSinkholeCert(
          host: 'example.com',
          issuedToCName: null,
          issuedByCName: null,
        ),
        isFalse,
      );
    });
  });
}
