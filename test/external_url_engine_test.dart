import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/external_url_engine.dart';

void main() {
  group('ExternalUrlParser.parse', () {
    test('returns null for http(s) URLs', () {
      expect(ExternalUrlParser.parse('https://example.com/'), isNull);
      expect(ExternalUrlParser.parse('http://example.com/foo?bar=1'), isNull);
    });

    test('returns null for other internal schemes', () {
      expect(ExternalUrlParser.parse('about:blank'), isNull);
      expect(ExternalUrlParser.parse('data:text/html,hi'), isNull);
      expect(ExternalUrlParser.parse('blob:https://example.com/abc'), isNull);
      expect(ExternalUrlParser.parse('file:///tmp/x.html'), isNull);
      expect(ExternalUrlParser.parse('javascript:void(0)'), isNull);
      expect(ExternalUrlParser.parse('view-source:https://example.com/'), isNull);
    });

    test('returns null for chrome-family internal schemes', () {
      // Rendered by the Chromium engine inside Android WebView; not OS
      // app launches.
      expect(ExternalUrlParser.parse('chrome://version'), isNull);
      expect(ExternalUrlParser.parse('chrome://gpu'), isNull);
      expect(ExternalUrlParser.parse('chrome-extension://abcd/popup.html'), isNull);
      expect(ExternalUrlParser.parse('chrome-error://chromewebdata/'), isNull);
      expect(ExternalUrlParser.parse('chrome-search://local-ntp'), isNull);
      expect(ExternalUrlParser.parse('chrome-untrusted://nope'), isNull);
    });

    test('returns null for URLs with empty scheme', () {
      expect(ExternalUrlParser.parse('/relative/path'), isNull);
      expect(ExternalUrlParser.parse(''), isNull);
    });

    test('captures scheme for tel: and mailto:', () {
      final tel = ExternalUrlParser.parse('tel:+14155551234')!;
      expect(tel.scheme, 'tel');
      expect(tel.package, isNull);
      expect(tel.fallbackUrl, isNull);

      final mail = ExternalUrlParser.parse('mailto:foo@example.com?subject=hi')!;
      expect(mail.scheme, 'mailto');
      expect(mail.package, isNull);
    });

    test('captures scheme and host for custom app schemes', () {
      final fb = ExternalUrlParser.parse('fb://profile/123')!;
      expect(fb.scheme, 'fb');
      expect(fb.host, 'profile');
    });

    test('parses Google Maps intent:// with fallback URL', () {
      const url =
          'intent://www.google.com/maps?entry=ml&utm_campaign=ml-ardi-wv&coh=230964'
          '#Intent;scheme=https;package=com.google.android.apps.maps;'
          'S.browser_fallback_url=https%3A%2F%2Fwww.google.com%2Fmaps%3Fentry%3Dml'
          '%26utm_campaign%3Dml-ardi-wv%26coh%3D230964;end;';
      final info = ExternalUrlParser.parse(url)!;
      expect(info.scheme, 'intent');
      expect(info.host, 'www.google.com');
      expect(info.package, 'com.google.android.apps.maps');
      expect(info.targetScheme, 'https');
      expect(
        info.fallbackUrl,
        'https://www.google.com/maps?entry=ml&utm_campaign=ml-ardi-wv&coh=230964',
      );
    });

    test('parses intent:// without fallback URL', () {
      const url =
          'intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end';
      final info = ExternalUrlParser.parse(url)!;
      expect(info.scheme, 'intent');
      expect(info.package, 'com.google.zxing.client.android');
      expect(info.targetScheme, 'zxing');
      expect(info.fallbackUrl, isNull);
    });

    test('intent:// with trailing semicolon before end parses cleanly', () {
      const url = 'intent://x/#Intent;package=com.example;end;';
      final info = ExternalUrlParser.parse(url)!;
      expect(info.package, 'com.example');
    });

    test('scheme match is case-insensitive', () {
      expect(ExternalUrlParser.parse('HTTPS://example.com/'), isNull);
      final info = ExternalUrlParser.parse('INTENT://x/#Intent;end');
      expect(info?.scheme, 'intent');
    });
  });

  group('ExternalUrlParser.intentToWebUrl', () {
    test('returns null for non-intent schemes', () {
      final tel = ExternalUrlParser.parse('tel:+14155551234')!;
      expect(ExternalUrlParser.intentToWebUrl(tel), isNull);
    });

    test('prefers explicit browser_fallback_url', () {
      const url =
          'intent://www.google.com/maps?entry=ml&utm_campaign=ml-ardi-wv&coh=230964'
          '#Intent;scheme=https;package=com.google.android.apps.maps;'
          'S.browser_fallback_url=https%3A%2F%2Fwww.google.com%2Fmaps%3Fentry%3Dml'
          '%26utm_campaign%3Dml-ardi-wv%26coh%3D230964;end;';
      final info = ExternalUrlParser.parse(url)!;
      expect(
        ExternalUrlParser.intentToWebUrl(info),
        'https://www.google.com/maps?entry=ml&utm_campaign=ml-ardi-wv&coh=230964',
      );
    });

    test('reconstructs from targetScheme + host + path + query when no fallback', () {
      const url =
          'intent://www.google.com/maps?entry=ml#Intent;scheme=https;package=x;end';
      final info = ExternalUrlParser.parse(url)!;
      expect(info.fallbackUrl, isNull);
      expect(
        ExternalUrlParser.intentToWebUrl(info),
        'https://www.google.com/maps?entry=ml',
      );
    });

    test('returns null when targetScheme is non-http (e.g. zxing) and no fallback', () {
      const url =
          'intent://scan/#Intent;scheme=zxing;package=com.google.zxing.client.android;end';
      final info = ExternalUrlParser.parse(url)!;
      expect(ExternalUrlParser.intentToWebUrl(info), isNull);
    });

    test('returns null when fallback is non-http and no http target scheme', () {
      const url =
          'intent://scan/#Intent;scheme=zxing;'
          'S.browser_fallback_url=zxing%3A%2F%2Fscan%2F;end';
      final info = ExternalUrlParser.parse(url)!;
      expect(ExternalUrlParser.intentToWebUrl(info), isNull);
    });
  });

  group('ExternalUrlParser.toWebUrl', () {
    test('x-safari-https strips to https (x.com Safari bounce)', () {
      final info =
          ExternalUrlParser.parse('x-safari-https://redirect.x.com/?ct=rw-null')!;
      expect(info.scheme, 'x-safari-https');
      expect(
        ExternalUrlParser.toWebUrl(info),
        'https://redirect.x.com/?ct=rw-null',
      );
    });

    test('x-safari-http strips to http', () {
      final info = ExternalUrlParser.parse('x-safari-http://example.com/a?b=1')!;
      expect(ExternalUrlParser.toWebUrl(info), 'http://example.com/a?b=1');
    });

    test('uppercase scheme resolves (Uri lowercases, raw prefix preserved)', () {
      final info =
          ExternalUrlParser.parse('X-Safari-HTTPS://Example.com/Path')!;
      expect(ExternalUrlParser.toWebUrl(info), 'https://Example.com/Path');
    });

    test('x-safari without :// returns null', () {
      final info = ExternalUrlInfo(
        url: 'x-safari-https:opaque',
        scheme: 'x-safari-https',
      );
      expect(ExternalUrlParser.toWebUrl(info), isNull);
    });

    test('x-safari with empty host returns null', () {
      final info = ExternalUrlParser.parse('x-safari-https:///path-only');
      expect(info, isNotNull);
      expect(ExternalUrlParser.toWebUrl(info!), isNull);
    });

    test('other x-safari-* schemes are not resolved', () {
      final info = ExternalUrlParser.parse('x-safari-file://etc/passwd')!;
      expect(ExternalUrlParser.toWebUrl(info), isNull);
    });

    test('delegates intent:// to intentToWebUrl', () {
      const url =
          'intent://www.google.com/maps?entry=ml#Intent;scheme=https;package=x;end';
      final info = ExternalUrlParser.parse(url)!;
      expect(
        ExternalUrlParser.toWebUrl(info),
        ExternalUrlParser.intentToWebUrl(info),
      );
      expect(ExternalUrlParser.toWebUrl(info), 'https://www.google.com/maps?entry=ml');
    });

    test('returns null for schemes with no web equivalent', () {
      final tel = ExternalUrlParser.parse('tel:+14155551234')!;
      expect(ExternalUrlParser.toWebUrl(tel), isNull);
      final fb = ExternalUrlParser.parse('fb://profile/123')!;
      expect(ExternalUrlParser.toWebUrl(fb), isNull);
    });
  });

  group('intent browser_fallback_url scheme allowlist', () {
    // A page hands us the whole intent:// string, so browser_fallback_url is
    // attacker-influenced. A non-http(s) fallback must never resolve to a
    // loadable URL (silent route) and must never pass isLoadableWebUrl (the
    // gate the confirmation-dialog "Open in browser" button relies on).
    String intentWithFallback(String fallback) {
      final enc = Uri.encodeComponent(fallback);
      return 'intent://scan/#Intent;scheme=zxing;'
          'S.browser_fallback_url=$enc;end';
    }

    for (final hostile in const [
      'javascript:alert(document.cookie)',
      'file:///data/data/org.codeberg.theoden8.webspace/shared_prefs/x.xml',
      'data:text/html,<script>alert(1)</script>',
      'intent://evil/#Intent;scheme=zxing;end',
      'content://com.evil/secret',
    ]) {
      test('rejects $hostile fallback', () {
        final info = ExternalUrlParser.parse(intentWithFallback(hostile))!;
        expect(ExternalUrlParser.intentToWebUrl(info), isNull);
        expect(ExternalUrlParser.toWebUrl(info), isNull);
        expect(ExternalUrlParser.isLoadableWebUrl(hostile), isFalse);
      });
    }

    test('accepts an http(s) fallback', () {
      final info =
          ExternalUrlParser.parse(intentWithFallback('https://example.com/x'))!;
      expect(ExternalUrlParser.toWebUrl(info), 'https://example.com/x');
      expect(ExternalUrlParser.isLoadableWebUrl('https://example.com/x'), isTrue);
      expect(ExternalUrlParser.isLoadableWebUrl('http://example.com'), isTrue);
    });

    test('toWebUrl never yields a non-http(s) string for hostile intents', () {
      for (final hostile in const [
        'javascript:alert(1)',
        'file:///etc/passwd',
        'data:text/html,x',
        'intent://x/#Intent;scheme=zxing;end',
      ]) {
        final info = ExternalUrlParser.parse(
            'intent://x/#Intent;scheme=zxing;'
            'S.browser_fallback_url=${Uri.encodeComponent(hostile)};end')!;
        final resolved = ExternalUrlParser.toWebUrl(info);
        if (resolved != null) {
          expect(ExternalUrlParser.isLoadableWebUrl(resolved), isTrue);
        }
      }
    });
  });

  group('isLoadableWebUrl', () {
    test('only http and https are loadable', () {
      expect(ExternalUrlParser.isLoadableWebUrl('https://x'), isTrue);
      expect(ExternalUrlParser.isLoadableWebUrl('http://x'), isTrue);
      expect(ExternalUrlParser.isLoadableWebUrl('HTTPS://X'), isTrue);
      for (final bad in const [
        'file:///etc/passwd',
        'javascript:alert(1)',
        'data:text/html,x',
        'intent://x',
        'tel:+1',
        'x-safari-https://x',
        'about:blank',
        '',
        'not a url with spaces',
      ]) {
        expect(ExternalUrlParser.isLoadableWebUrl(bad), isFalse,
            reason: '$bad must not be loadable');
      }
    });
  });
}
