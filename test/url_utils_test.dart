import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/utils/url_utils.dart';

void main() {
  group('hasUrlScheme', () {
    test('detects http/https schemes', () {
      expect(hasUrlScheme('http://example.com'), isTrue);
      expect(hasUrlScheme('https://example.com'), isTrue);
    });

    test('detects chrome:// and other browser-internal schemes', () {
      expect(hasUrlScheme('chrome://flags'), isTrue);
      expect(hasUrlScheme('chrome://version'), isTrue);
      expect(hasUrlScheme('about:blank'), isTrue);
      expect(hasUrlScheme('file:///tmp/index.html'), isTrue);
      expect(hasUrlScheme('javascript:alert(1)'), isTrue);
      expect(hasUrlScheme('data:text/html,<h1>hi</h1>'), isTrue);
      expect(hasUrlScheme('mailto:foo@example.com'), isTrue);
    });

    test('bare hostnames have no scheme', () {
      expect(hasUrlScheme('example.com'), isFalse);
      expect(hasUrlScheme('www.example.com'), isFalse);
      expect(hasUrlScheme('localhost'), isFalse);
    });

    test('host:port is not classified as a scheme', () {
      expect(hasUrlScheme('example.com:8080'), isFalse);
      expect(hasUrlScheme('192.168.1.1:3000'), isFalse);
      expect(hasUrlScheme('localhost:8080'), isFalse);
    });
  });

  group('ensureUrlScheme', () {
    test('prepends https:// to bare hostnames', () {
      expect(ensureUrlScheme('example.com'), 'https://example.com');
      expect(ensureUrlScheme('example.com:8080'), 'https://example.com:8080');
      expect(ensureUrlScheme('localhost'), 'https://localhost');
    });

    test('preserves chrome:// and other schemes', () {
      expect(ensureUrlScheme('chrome://flags'), 'chrome://flags');
      expect(ensureUrlScheme('about:blank'), 'about:blank');
      expect(ensureUrlScheme('file:///tmp/x.html'), 'file:///tmp/x.html');
      expect(ensureUrlScheme('http://example.com'), 'http://example.com');
      expect(ensureUrlScheme('https://example.com'), 'https://example.com');
    });
  });
}
