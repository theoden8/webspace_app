import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';

/// Tests for the file-import-sites feature.
///
/// The main import flow (_importHtmlFile) depends on FilePicker (platform
/// plugin) so cannot be unit-tested directly.  These tests verify the
/// filename-to-name derivation logic and the result map contract that
/// AddSiteScreen returns to _addSite().

void main() {
  group('Filename to site name', () {
    // Mirrors the logic in _importHtmlFile:
    // nameWithoutExt = fileName.replaceAll(RegExp(r'\.(html?|htm)$', caseSensitive: false), '');
    String nameFromFile(String fileName) {
      return fileName.replaceAll(
          RegExp(r'\.(html?|htm)$', caseSensitive: false), '');
    }

    test('strips .html extension', () {
      expect(nameFromFile('my-page.html'), 'my-page');
    });

    test('strips .htm extension', () {
      expect(nameFromFile('report.htm'), 'report');
    });

    test('is case-insensitive for extension', () {
      expect(nameFromFile('Page.HTML'), 'Page');
      expect(nameFromFile('Doc.HTM'), 'Doc');
    });

    test('preserves name with dots not at end', () {
      expect(nameFromFile('v2.0-release.html'), 'v2.0-release');
    });

    test('preserves spaces in filename', () {
      expect(nameFromFile('My Document.html'), 'My Document');
    });

    test('handles unicode filenames', () {
      expect(nameFromFile('página.html'), 'página');
    });
  });

  group('Result map contract', () {
    test('file import result contains required keys', () {
      // Simulates the Map returned by _importHtmlFile
      final result = <String, dynamic>{
        'url': 'file:///test.html',
        'name': 'test',
        'incognito': false,
        'htmlContent': '<html><body>Hello</body></html>',
      };

      expect(result['url'], startsWith('file:///'));
      expect(result['name'], isNotEmpty);
      expect(result['htmlContent'], isA<String>());
      expect((result['htmlContent'] as String).isNotEmpty, isTrue);
    });

    test('file import result with incognito mode', () {
      final result = <String, dynamic>{
        'url': 'file:///test.html',
        'name': 'test',
        'incognito': true,
        'htmlContent': '<html><body>Hello</body></html>',
      };

      expect(result['incognito'], isTrue);
    });

    test('htmlContent is null for regular URL sites', () {
      // Regular URL-based site (existing behavior)
      final result = <String, dynamic>{
        'url': 'https://example.com',
        'name': '',
        'incognito': false,
      };

      expect(result['htmlContent'], isNull);
    });

    test('url for imported file uses file:/// scheme (three slashes)', () {
      final fileName = 'report.html';
      final url = 'file:///$fileName';

      // Three-slash form: empty authority, real path. The two-slash
      // form `file://report.html` parses with `report.html` as the
      // host and chromium rejects it with ERR_INVALID_URL whenever the
      // cached HTML is unavailable (incognito, post-upgrade wipe).
      expect(url, 'file:///report.html');
      final parsed = Uri.tryParse(url);
      expect(parsed?.scheme, 'file');
      expect(parsed?.host, isEmpty);
      expect(parsed?.path, '/report.html');
    });
  });

  group('Fallback HTML when cache is missing', () {
    test('renders the filename without the file:// scheme prefix', () {
      final html = buildFileImportFallbackHtml('file:///notifs.html');

      expect(html, contains('<code>notifs.html</code>'));
      expect(html, contains('Imported file unavailable'));
      // Don't leak the synthetic URL scheme into user-visible copy.
      expect(html, isNot(contains('file:///notifs.html')));
    });

    test('handles legacy two-slash URLs that survived migration', () {
      // Defensive: even if a model snuck through without migrating, the
      // fallback shouldn't render `//notifs.html` to the user.
      final html = buildFileImportFallbackHtml('file://notifs.html');

      expect(html, contains('<code>notifs.html</code>'));
    });

    test('handles chromium-normalised URLs with trailing slash', () {
      final html = buildFileImportFallbackHtml('file://notifs.html/');

      expect(html, contains('<code>notifs.html</code>'));
    });

    test('escapes HTML metacharacters in the filename', () {
      // FilePicker doesn't normally allow these, but be defensive — a
      // crafted filename from a sandbox bypass shouldn't inject markup
      // into the fallback page.
      final html = buildFileImportFallbackHtml('file:///<script>.html');

      expect(html, isNot(contains('<script>.html')));
      expect(html, contains('&lt;script&gt;.html'));
    });
  });

  group('URL type detection', () {
    test('file:// URLs are distinguishable from http(s)', () {
      expect('file:///page.html'.startsWith('file://'), isTrue);
      expect('https://example.com'.startsWith('file://'), isFalse);
      expect('http://example.com'.startsWith('file://'), isFalse);
    });

    test('htmlContent presence indicates file import', () {
      final fileResult = <String, dynamic>{
        'url': 'file:///page.html',
        'name': 'page',
        'incognito': false,
        'htmlContent': '<html></html>',
      };
      final urlResult = <String, dynamic>{
        'url': 'https://example.com',
        'name': '',
        'incognito': false,
      };

      expect(fileResult['htmlContent'] != null, isTrue);
      expect(urlResult['htmlContent'], isNull);
    });
  });
}
