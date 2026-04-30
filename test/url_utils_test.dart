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

  group('migrateLegacyFileImportUrl', () {
    test('rewrites legacy two-slash file:// URLs to three-slash form', () {
      // Legacy `file://name.html` parses with `name.html` as the host;
      // chromium rejects it with ERR_INVALID_URL on direct load.
      expect(migrateLegacyFileImportUrl('file://notifs.html'),
          'file:///notifs.html');
      expect(migrateLegacyFileImportUrl('file://report.html'),
          'file:///report.html');
    });

    test('preserves trailing slash that chromium adds when normalising', () {
      // `currentUrl` saved off chromium's onUrlChanged for a legacy
      // import is `file://name.html/` — host=name.html, path=/.
      expect(migrateLegacyFileImportUrl('file://notifs.html/'),
          'file:///notifs.html/');
    });

    test('leaves already-canonical file:/// URLs alone (idempotent)', () {
      expect(migrateLegacyFileImportUrl('file:///tmp/x.html'),
          'file:///tmp/x.html');
      expect(migrateLegacyFileImportUrl('file:///notifs.html'),
          'file:///notifs.html');
    });

    test('leaves non-file URLs alone', () {
      expect(migrateLegacyFileImportUrl('https://example.com'),
          'https://example.com');
      expect(migrateLegacyFileImportUrl('about:blank'), 'about:blank');
      expect(migrateLegacyFileImportUrl('chrome://flags'), 'chrome://flags');
      expect(migrateLegacyFileImportUrl(''), '');
    });
  });
}
