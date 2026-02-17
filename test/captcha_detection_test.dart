import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';

void main() {
  group('Captcha Detection', () {
    group('Cloudflare', () {
      test('challenges.cloudflare.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://challenges.cloudflare.com/turnstile/v0/api.js'),
          isTrue,
        );
      });

      test('subdomain of challenges.cloudflare.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://sub.challenges.cloudflare.com/something'),
          isTrue,
        );
      });

      test('cdn-cgi/challenge-platform path is detected on any domain', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://example.com/cdn-cgi/challenge-platform/scripts/turnstile'),
          isTrue,
        );
      });

      test('cf-turnstile in URL is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://example.com/cf-turnstile/widget'),
          isTrue,
        );
      });
    });

    group('hCaptcha', () {
      test('hcaptcha.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://hcaptcha.com/1/api.js'),
          isTrue,
        );
      });

      test('subdomain of hcaptcha.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge(
            'https://newassets.hcaptcha.com/captcha/v1/cf4a5d4/static/hcaptcha.html#frame=challenge&id=abc',
          ),
          isTrue,
        );
      });

      test('nothcaptcha.com is NOT detected (no partial match)', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://nothcaptcha.com/api.js'),
          isFalse,
        );
      });
    });

    group('reCAPTCHA', () {
      test('/recaptcha/ on google.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://www.google.com/recaptcha/api2/anchor?k=abc'),
          isTrue,
        );
      });

      test('/recaptcha/ on gstatic.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://www.gstatic.com/recaptcha/releases/abc/recaptcha__en.js'),
          isTrue,
        );
      });

      test('/recaptcha/ on recaptcha.net is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://recaptcha.net/recaptcha/api.js'),
          isTrue,
        );
      });

      test('/recaptcha/ on googleapis.com is detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://www.googleapis.com/recaptcha/v3/siteVerify'),
          isTrue,
        );
      });

      test('/recaptcha/ on evil.com is NOT detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://evil.com/recaptcha/payload'),
          isFalse,
        );
      });

      test('/recaptcha/ on random domain is NOT detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://attacker.io/recaptcha/fake'),
          isFalse,
        );
      });

      test('recaptcha in query string on evil domain is NOT detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://evil.com/page?path=/recaptcha/'),
          isFalse,
        );
      });
    });

    group('Non-captcha URLs', () {
      test('regular website is not detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://example.com/page'),
          isFalse,
        );
      });

      test('google.com without /recaptcha/ is not detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('https://www.google.com/search?q=test'),
          isFalse,
        );
      });

      test('empty string is not detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge(''),
          isFalse,
        );
      });

      test('invalid URL is not detected', () {
        expect(
          WebViewFactory.isCaptchaChallenge('not-a-url'),
          isFalse,
        );
      });
    });
  });
}
