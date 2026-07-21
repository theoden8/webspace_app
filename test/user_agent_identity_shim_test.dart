import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity_shim.dart';

const _chromeAndroid =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
const _safariMac =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 '
    '(KHTML, like Gecko) Version/17.4 Safari/605.1.15';
const _criOs =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/120.0.0.0 '
    'Mobile/15E148 Safari/604.1';

void main() {
  group('inferUaEngine', () {
    test('Gecko: Firefox desktop + Android', () {
      expect(inferUaEngine(firefoxLinuxDesktopUserAgent), UaEngine.gecko);
      expect(inferUaEngine(buildFirefoxAndroidUserAgent('152.0')),
          UaEngine.gecko);
    });

    test('WebKit: Safari, FxiOS, and CriOS (iOS is always WebKit)', () {
      expect(inferUaEngine(_safariMac), UaEngine.webkit);
      expect(inferUaEngine(buildFirefoxIosUserAgent('152.0')), UaEngine.webkit);
      // CriOS carries no "Chrome/" token and is iOS => WebKit, not Blink.
      expect(inferUaEngine(_criOs), UaEngine.webkit);
    });

    test('Blink: Chrome for Android and desktop', () {
      expect(inferUaEngine(_chromeAndroid), UaEngine.blink);
      expect(
          inferUaEngine(
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'),
          UaEngine.blink);
    });

    test('unknown for empty / unrecognized', () {
      expect(inferUaEngine(null), UaEngine.unknown);
      expect(inferUaEngine(''), UaEngine.unknown);
      expect(inferUaEngine('curl/8.0'), UaEngine.unknown);
    });
  });

  group('buildUserAgentIdentityShim', () {
    test('returns null when the engine is unclassifiable', () {
      expect(buildUserAgentIdentityShim(''), isNull);
      expect(buildUserAgentIdentityShim('curl/8.0'), isNull);
    });

    test('Gecko mobile (Firefox-Android): empty vendor, gecko productSub, '
        'frozen oscpu/buildID, mobile platform', () {
      final s = buildUserAgentIdentityShim(buildFirefoxAndroidUserAgent('152.0'))!;
      expect(s, contains("def('vendor', \"\");"));
      expect(s, contains("def('vendorSub', '');"));
      expect(s, contains("def('productSub', \"20100101\");"));
      expect(s, contains("def('oscpu', \"Linux armv8l\");"));
      expect(s, contains("def('buildID', '20181001000000');"));
      expect(s, contains("def('platform', \"Linux armv8l\");"));
      expect(s, contains('__ws_ua_identity_shim__'));
      // The builder must NOT append the evaluator-return; the call site does.
      expect(s.trimRight().endsWith('})();'), isTrue);
    });

    test('Gecko desktop: desktop oscpu, and NO platform override '
        '(desktop_mode_shim owns platform)', () {
      final s = buildUserAgentIdentityShim(firefoxLinuxDesktopUserAgent)!;
      expect(s, contains("def('oscpu', \"Linux x86_64\");"));
      expect(s, contains("def('buildID', '20181001000000');"));
      expect(s, isNot(contains("def('platform'")));
    });

    test('Gecko desktop windows/macos oscpu tokens', () {
      expect(buildUserAgentIdentityShim(firefoxWindowsDesktopUserAgent)!,
          contains("def('oscpu', \"Windows NT 10.0; Win64; x64\");"));
      expect(buildUserAgentIdentityShim(firefoxMacosDesktopUserAgent)!,
          contains("def('oscpu', \"Intel Mac OS X 10.15\");"));
    });

    test('WebKit mobile (FxiOS): Apple vendor, webkit productSub, '
        'oscpu/buildID/userAgentData removed, iPhone platform', () {
      final s = buildUserAgentIdentityShim(buildFirefoxIosUserAgent('152.0'))!;
      expect(s, contains("def('vendor', \"Apple Computer, Inc.\");"));
      expect(s, contains("def('productSub', \"20030107\");"));
      expect(s, contains("removeProp('oscpu');"));
      expect(s, contains("removeProp('buildID');"));
      expect(s, contains("removeProp('userAgentData');"));
      expect(s, contains("def('platform', \"iPhone\");"));
    });

    test('Blink mobile (Chrome-Android): Google vendor, webkit productSub, '
        'no oscpu, keeps userAgentData', () {
      final s = buildUserAgentIdentityShim(_chromeAndroid)!;
      expect(s, contains("def('vendor', \"Google Inc.\");"));
      expect(s, contains("def('productSub', \"20030107\");"));
      expect(s, contains("removeProp('oscpu');"));
      expect(s, contains("def('platform', \"Linux armv8l\");"));
      // Blink keeps userAgentData — it must NOT be removed.
      expect(s, isNot(contains("removeProp('userAgentData')")));
    });
  });
}
