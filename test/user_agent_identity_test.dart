import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity.dart';

void main() {
  group('describeUserAgent browser + OS', () {
    test('generated Firefox desktop shapes', () {
      final linux = describeUserAgent(firefoxLinuxDesktopUserAgent);
      expect(linux.browser, UaBrowser.firefox);
      expect(linux.browserVersion, '$kDefaultFirefoxMajorVersion');
      expect(linux.os, UaOs.linux);
      expect(linux.issues, isEmpty);

      final windows = describeUserAgent(firefoxWindowsDesktopUserAgent);
      expect(windows.os, UaOs.windows);
      expect(windows.osVersion, '10.0');

      final macos = describeUserAgent(firefoxMacosDesktopUserAgent);
      expect(macos.os, UaOs.macos);
      expect(macos.osVersion, '10.15');
    });

    test('generated Firefox mobile shapes', () {
      final android = describeUserAgent(buildFirefoxAndroidUserAgent('152.0'));
      expect(android.browser, UaBrowser.firefox);
      expect(android.browserVersion, '152');
      expect(android.os, UaOs.android);

      final ios = describeUserAgent(buildFirefoxIosUserAgent('152.0'));
      expect(ios.browser, UaBrowser.firefox);
      expect(ios.browserVersion, '152');
      expect(ios.os, UaOs.ios);
      expect(ios.osVersion, '18.7');
      expect(ios.issues, isEmpty);
    });

    test('real third-party browsers', () {
      final chrome = describeUserAgent(
          'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36');
      expect(chrome.browser, UaBrowser.chrome);
      expect(chrome.browserVersion, '137');
      expect(chrome.os, UaOs.linux);

      final safari = describeUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
          'Mobile/15E148 Safari/604.1');
      expect(safari.browser, UaBrowser.safari);
      expect(safari.browserVersion, '17');
      expect(safari.os, UaOs.ios);
      expect(safari.osVersion, '17.5');

      final edge = describeUserAgent(
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36 Edg/137.0.0.0');
      expect(edge.browser, UaBrowser.edge);
      expect(edge.os, UaOs.windows);

      final samsung = describeUserAgent(
          'Mozilla/5.0 (Linux; Android 14; SAMSUNG SM-S918B) '
          'AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/25.0 '
          'Chrome/121.0.0.0 Mobile Safari/537.36');
      expect(samsung.browser, UaBrowser.samsungInternet);
      expect(samsung.os, UaOs.android);
      expect(samsung.osVersion, '14');
    });

    test('empty string yields unknown identity with no issues', () {
      final id = describeUserAgent('');
      expect(id.browser, UaBrowser.unknown);
      expect(id.os, UaOs.unknown);
      expect(id.issues, isEmpty);
    });
  });

  group('describeUserAgent validity issues', () {
    test('stock WKWebView default carries the webview tell (BUG-005)', () {
      final id = describeUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148');
      expect(id.browser, UaBrowser.webview);
      expect(id.os, UaOs.ios);
      expect(id.osVersion, '18.7');
      expect(id.issues, contains(UaIssue.embeddedWebViewTell));
    });

    test('Android wv token is a webview tell', () {
      final id = describeUserAgent(
          'Mozilla/5.0 (Linux; Android 14; Pixel 7 Build/X; wv) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
          'Chrome/137.0.7151.61 Mobile Safari/537.36');
      expect(id.browser, UaBrowser.webview);
      expect(id.issues, contains(UaIssue.embeddedWebViewTell));
    });

    test('rv:/Firefox mismatch is flagged', () {
      final id = describeUserAgent(
          'Mozilla/5.0 (X11; Linux x86_64; rv:151.0) '
          'Gecko/20100101 Firefox/152.0');
      expect(id.issues, contains(UaIssue.geckoVersionMismatch));
    });

    test('pre-#410 iPhone-in-Gecko hybrid is flagged impossible', () {
      final id = describeUserAgent(
          'Mozilla/5.0 (iPhone; CPU iPhone OS 15_7_3 like Mac OS X; '
          'rv:147.0) Gecko/20100101 Firefox/147.0');
      expect(id.issues, contains(UaIssue.impossibleHybrid));
    });

    test('stale Firefox version flagged only when current is known', () {
      final stale = describeUserAgent(firefoxLinuxDesktopUserAgent,
          currentFirefoxMajor: kDefaultFirefoxMajorVersion + 5);
      expect(stale.issues, contains(UaIssue.staleFirefoxVersion));

      final current = describeUserAgent(firefoxLinuxDesktopUserAgent,
          currentFirefoxMajor: kDefaultFirefoxMajorVersion);
      expect(current.issues, isNot(contains(UaIssue.staleFirefoxVersion)));

      final unchecked = describeUserAgent(firefoxLinuxDesktopUserAgent);
      expect(unchecked.issues, isNot(contains(UaIssue.staleFirefoxVersion)));
    });

    test('garbage is malformed', () {
      final id = describeUserAgent('MyBrowser/1.0');
      expect(id.issues, contains(UaIssue.malformed));
      expect(id.browser, UaBrowser.unknown);
    });
  });
}
