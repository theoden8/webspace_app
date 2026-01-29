import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/web_view_model.dart';

// Test the URL blocking logic for captcha support
// This mirrors the _shouldBlockUrl function in webview.dart

bool shouldBlockUrl(String url) {
  // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile
  if (url.startsWith('about:') && url != 'about:blank' && url != 'about:srcdoc') return true;
  if (url.contains('/sw_iframe.html') || url.contains('/blank.html') || url.contains('/service_worker/')) return true;

  const trackingDomains = [
    'googletagmanager.com', 'google-analytics.com', 'googleadservices.com',
    'doubleclick.net', 'facebook.com/tr', 'connect.facebook.net',
    'analytics.twitter.com', 'static.ads-twitter.com',
  ];
  return trackingDomains.any((d) => url.contains(d));
}

void main() {
  group('Captcha Support - URL Blocking', () {
    group('about: URL handling', () {
      test('about:blank should be allowed', () {
        expect(shouldBlockUrl('about:blank'), isFalse);
      });

      test('about:srcdoc should be allowed', () {
        expect(shouldBlockUrl('about:srcdoc'), isFalse);
      });

      test('other about: URLs should be blocked', () {
        expect(shouldBlockUrl('about:invalid'), isTrue);
        expect(shouldBlockUrl('about:config'), isTrue);
        expect(shouldBlockUrl('about:version'), isTrue);
        expect(shouldBlockUrl('about:'), isTrue);
        expect(shouldBlockUrl('about:debugging'), isTrue);
      });

      test('about: with different casing should be handled correctly', () {
        // The check is case-sensitive, which matches browser behavior
        expect(shouldBlockUrl('About:blank'), isFalse); // doesn't start with 'about:'
        expect(shouldBlockUrl('ABOUT:BLANK'), isFalse); // doesn't start with 'about:'
      });
    });

    group('Cloudflare challenge URLs', () {
      test('challenges.cloudflare.com should not be blocked by shouldBlockUrl', () {
        expect(shouldBlockUrl('https://challenges.cloudflare.com/cdn-cgi/challenge-platform/h/b/turnstile/if/ov2/av0/rcv0/0/q0yru/0x4AAAAAAA'), isFalse);
      });

      test('cloudflare cdn-cgi challenge URLs should not be blocked', () {
        expect(shouldBlockUrl('https://example.com/cdn-cgi/challenge-platform/scripts/jsd/main.js'), isFalse);
      });
    });

    group('Service worker iframes (blocked)', () {
      test('sw_iframe.html should be blocked', () {
        expect(shouldBlockUrl('https://example.com/sw_iframe.html'), isTrue);
      });

      test('blank.html should be blocked', () {
        expect(shouldBlockUrl('https://example.com/blank.html'), isTrue);
      });

      test('service_worker paths should be blocked', () {
        expect(shouldBlockUrl('https://example.com/service_worker/register.js'), isTrue);
      });
    });

    group('Tracking domains (blocked)', () {
      test('googletagmanager.com should be blocked', () {
        expect(shouldBlockUrl('https://www.googletagmanager.com/gtag/js'), isTrue);
      });

      test('google-analytics.com should be blocked', () {
        expect(shouldBlockUrl('https://www.google-analytics.com/analytics.js'), isTrue);
      });

      test('facebook tracking should be blocked', () {
        expect(shouldBlockUrl('https://www.facebook.com/tr/pixel'), isTrue);
        expect(shouldBlockUrl('https://connect.facebook.net/sdk.js'), isTrue);
      });

      test('twitter analytics should be blocked', () {
        expect(shouldBlockUrl('https://analytics.twitter.com/i/adsct'), isTrue);
        expect(shouldBlockUrl('https://static.ads-twitter.com/uwt.js'), isTrue);
      });

      test('doubleclick should be blocked', () {
        expect(shouldBlockUrl('https://ad.doubleclick.net/ddm/activity'), isTrue);
      });
    });

    group('Regular URLs (allowed)', () {
      test('normal HTTPS URLs should be allowed', () {
        expect(shouldBlockUrl('https://example.com'), isFalse);
        expect(shouldBlockUrl('https://gitlab.com/users/sign_in'), isFalse);
        expect(shouldBlockUrl('https://github.com'), isFalse);
      });

      test('HTTP URLs should be allowed', () {
        expect(shouldBlockUrl('http://example.com'), isFalse);
      });

      test('data URLs should be allowed', () {
        expect(shouldBlockUrl('data:text/html,<h1>Test</h1>'), isFalse);
      });

      test('javascript URLs should be allowed (but may be blocked elsewhere)', () {
        expect(shouldBlockUrl('javascript:void(0)'), isFalse);
      });
    });
  });

  group('Captcha Support - Cloudflare Detection', () {
    bool isCloudflareChallenge(String url) =>
        url.contains('challenges.cloudflare.com') ||
        url.contains('cloudflare.com/cdn-cgi/challenge') ||
        url.contains('cdn-cgi/challenge-platform') ||
        url.contains('turnstile.com') ||
        url.contains('cf-turnstile');

    test('challenges.cloudflare.com should be detected', () {
      expect(isCloudflareChallenge('https://challenges.cloudflare.com/turnstile/v0/api.js'), isTrue);
    });

    test('cdn-cgi/challenge-platform should be detected', () {
      expect(isCloudflareChallenge('https://example.com/cdn-cgi/challenge-platform/scripts/jsd/main.js'), isTrue);
    });

    test('turnstile.com should be detected', () {
      expect(isCloudflareChallenge('https://turnstile.com/widget'), isTrue);
    });

    test('cf-turnstile should be detected', () {
      expect(isCloudflareChallenge('https://example.com/cf-turnstile/widget'), isTrue);
    });

    test('regular URLs should not be detected as Cloudflare', () {
      expect(isCloudflareChallenge('https://gitlab.com'), isFalse);
      expect(isCloudflareChallenge('https://example.com'), isFalse);
    });
  });

  group('Captcha Support - Domain Comparison for about: URLs', () {
    // This tests the shouldOverrideUrlLoading logic in web_view_model.dart
    // The callback must allow about:blank and about:srcdoc without domain comparison

    /// Simulates the shouldOverrideUrlLoading callback logic
    bool shouldAllowNavigation(String requestUrl, String initUrl) {
      // Allow about:blank and about:srcdoc - required for Cloudflare Turnstile iframes
      if (requestUrl == 'about:blank' || requestUrl == 'about:srcdoc') {
        return true;
      }

      // Use normalized domain comparison
      final requestNormalized = getNormalizedDomain(requestUrl);
      final initialNormalized = getNormalizedDomain(initUrl);

      return requestNormalized == initialNormalized;
    }

    test('about:blank should be allowed regardless of initial URL', () {
      expect(shouldAllowNavigation('about:blank', 'https://gitlab.com'), isTrue);
      expect(shouldAllowNavigation('about:blank', 'https://github.com'), isTrue);
      expect(shouldAllowNavigation('about:blank', 'https://example.com'), isTrue);
    });

    test('about:srcdoc should be allowed regardless of initial URL', () {
      expect(shouldAllowNavigation('about:srcdoc', 'https://gitlab.com'), isTrue);
      expect(shouldAllowNavigation('about:srcdoc', 'https://github.com'), isTrue);
      expect(shouldAllowNavigation('about:srcdoc', 'https://example.com'), isTrue);
    });

    test('getNormalizedDomain returns different value for about: URLs', () {
      // Without the early return, domain comparison would fail
      // because getNormalizedDomain('about:blank') != getNormalizedDomain('https://gitlab.com')
      expect(getNormalizedDomain('about:blank'), isNot(equals('gitlab.com')));
      expect(getNormalizedDomain('about:srcdoc'), isNot(equals('gitlab.com')));
    });

    test('same domain navigation should be allowed', () {
      expect(shouldAllowNavigation('https://gitlab.com/dashboard', 'https://gitlab.com'), isTrue);
      expect(shouldAllowNavigation('https://www.gitlab.com/login', 'https://gitlab.com'), isTrue);
    });

    test('different domain navigation should be blocked', () {
      expect(shouldAllowNavigation('https://github.com', 'https://gitlab.com'), isFalse);
      expect(shouldAllowNavigation('https://example.com', 'https://gitlab.com'), isFalse);
    });
  });
}
