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

  group('uaIdentityFor', () {
    test('returns null when the engine is unclassifiable', () {
      expect(uaIdentityFor(''), isNull);
      expect(uaIdentityFor('curl/8.0'), isNull);
      expect(buildUserAgentIdentityShim('curl/8.0'), isNull);
    });

    test('Gecko mobile (Firefox-Android): empty vendor, gecko productSub, '
        'frozen oscpu/buildID, mobile platform', () {
      expect(uaIdentityFor(buildFirefoxAndroidUserAgent('152.0')), (
        vendor: '',
        productSub: '20100101',
        oscpu: 'Linux armv8l',
        buildID: '20181001000000',
        platform: 'Linux armv8l',
        removeUserAgentData: true,
      ));
    });

    test('Gecko desktop: desktop oscpu + platform (workers never get '
        'desktop_mode.js, so identity must carry platform)', () {
      final id = uaIdentityFor(firefoxLinuxDesktopUserAgent)!;
      expect(id.oscpu, 'Linux x86_64');
      expect(id.buildID, '20181001000000');
      expect(id.platform, 'Linux x86_64');
    });

    test('desktop platform matches what the desktop-mode shim emits', () {
      for (final ua in [
        firefoxLinuxDesktopUserAgent,
        firefoxMacosDesktopUserAgent,
        firefoxWindowsDesktopUserAgent,
      ]) {
        expect(uaIdentityFor(ua)!.platform,
            navigatorPlatformFor(inferDesktopUaPlatform(ua)));
      }
    });

    test('Gecko desktop windows/macos oscpu tokens', () {
      expect(uaIdentityFor(firefoxWindowsDesktopUserAgent)!.oscpu,
          'Windows NT 10.0; Win64; x64');
      expect(uaIdentityFor(firefoxMacosDesktopUserAgent)!.oscpu,
          'Intel Mac OS X 10.15');
    });

    test('WebKit mobile (FxiOS): Apple vendor, webkit productSub, '
        'oscpu/buildID/userAgentData removed, iPhone platform', () {
      expect(uaIdentityFor(buildFirefoxIosUserAgent('152.0')), (
        vendor: 'Apple Computer, Inc.',
        productSub: '20030107',
        oscpu: null,
        buildID: null,
        platform: 'iPhone',
        removeUserAgentData: true,
      ));
    });

    test('Blink mobile (Chrome-Android): Google vendor, webkit productSub, '
        'no oscpu, keeps userAgentData', () {
      expect(uaIdentityFor(_chromeAndroid), (
        vendor: 'Google Inc.',
        productSub: '20030107',
        oscpu: null,
        buildID: null,
        platform: 'Linux armv8l',
        removeUserAgentData: false,
      ));
    });

    test('the shim carries the identity as its config', () {
      final s = buildUserAgentIdentityShim(buildFirefoxIosUserAgent('152.0'))!;
      expect(s, contains('"vendor":"Apple Computer, Inc."'));
      expect(s, contains('"oscpu":null'));
      expect(s, contains('__ws_ua_identity_shim__'));
    });
  });
}
