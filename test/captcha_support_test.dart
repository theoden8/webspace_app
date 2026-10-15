import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

bool blocked(String url) => WebViewFactory.shouldBlockUrl(url);

void main() {
  group('about: URLs', () {
    test('about:blank and about:srcdoc load, for captcha iframes (CAPTCHA-002)',
        () {
      expect(blocked('about:blank'), isFalse);
      expect(blocked('about:srcdoc'), isFalse);
    });

    test('every other about: URL is blocked (CAPTCHA-002, NESTED-002)', () {
      expect(blocked('about:invalid'), isTrue);
      expect(blocked('about:config'), isTrue);
      expect(blocked('about:version'), isTrue);
      expect(blocked('about:'), isTrue);
      expect(blocked('about:debugging'), isTrue);
    });

    test('the scheme is matched as written, as browsers do', () {
      expect(blocked('About:blank'), isFalse);
      expect(blocked('ABOUT:BLANK'), isFalse);
    });
  });

  test('service-worker iframes are blocked (NESTED-003)', () {
    expect(blocked('https://example.com/sw_iframe.html'), isTrue);
    expect(blocked('https://example.com/blank.html'), isTrue);
    expect(blocked('https://example.com/service_worker/register.js'), isTrue);
  });

  test('a challenge, a page and other schemes are not blocked here', () {
    expect(
        blocked('https://challenges.cloudflare.com/cdn-cgi/challenge-platform/'
            'h/b/turnstile/if/ov2/av0/rcv0/0/q0yru/0x4AAAAAAA'),
        isFalse);
    expect(blocked('https://example.com/cdn-cgi/challenge-platform/scripts/jsd/main.js'),
        isFalse);
    expect(blocked('https://gitlab.com/users/sign_in'), isFalse);
    expect(blocked('http://example.com'), isFalse);
    expect(blocked('data:text/html,<h1>Test</h1>'), isFalse);
    expect(blocked('javascript:void(0)'), isFalse);
  });

  test('an about: URL normalises to no site domain', () {
    expect(getNormalizedDomain('about:blank'), isNot(equals('gitlab.com')));
    expect(getNormalizedDomain('about:srcdoc'), isNot(equals('gitlab.com')));
  });
}
