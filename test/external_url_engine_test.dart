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
}
