import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/user_agent_classifier.dart';

void main() {
  group('isDesktopUserAgent', () {
    test('empty / null UA is mobile', () {
      // Empty UA → webview falls back to its native mobile UA, so we must
      // classify it as mobile or we'd inject the desktop shim against a
      // real Android-WebView render.
      expect(isDesktopUserAgent(null), isFalse);
      expect(isDesktopUserAgent(''), isFalse);
    });

    test('Android Firefox UA is mobile', () {
      // The mobile end of generateRandomUserAgent's platform list.
      const ua = 'Mozilla/5.0 (Android 16; Mobile; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(isDesktopUserAgent(ua), isFalse);
    });

    test('Android Chrome (system WebView default) is mobile', () {
      const ua = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
          'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 '
          'Mobile Safari/537.36';
      expect(isDesktopUserAgent(ua), isFalse);
    });

    test('iPhone is mobile', () {
      const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
          'Mobile/15E148 Safari/604.1';
      expect(isDesktopUserAgent(ua), isFalse);
    });

    test('iPad is mobile', () {
      const ua = 'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) '
          'AppleWebKit/605.1.15';
      expect(isDesktopUserAgent(ua), isFalse);
    });

    test('Linux Firefox desktop is desktop', () {
      const ua = 'Mozilla/5.0 (X11; Linux x86_64; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(isDesktopUserAgent(ua), isTrue);
    });

    test('macOS Firefox desktop is desktop', () {
      const ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(isDesktopUserAgent(ua), isTrue);
    });

    test('Windows Firefox desktop is desktop', () {
      const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(isDesktopUserAgent(ua), isTrue);
    });

    test('Linux Chrome desktop is desktop', () {
      const ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36';
      expect(isDesktopUserAgent(ua), isTrue);
    });

    test('case-insensitive match on mobile markers', () {
      // Mixed case shouldn't fool the classifier.
      expect(isDesktopUserAgent('Some-bot/1.0 (ANDROID)'), isFalse);
      expect(isDesktopUserAgent('Some-bot/1.0 (iPhone simulator)'), isFalse);
    });
  });

  group('inferDesktopUaPlatform', () {
    test('detects macOS via "Macintosh"', () {
      const ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(inferDesktopUaPlatform(ua), DesktopUaPlatform.macos);
    });

    test('detects macOS via "Mac OS X" alone', () {
      // Older Safari UAs put "Mac OS X" but no "Macintosh" token.
      const ua = 'Mozilla/5.0 (Mac OS X) AppleWebKit Safari';
      expect(inferDesktopUaPlatform(ua), DesktopUaPlatform.macos);
    });

    test('detects Windows via "Windows NT"', () {
      const ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(inferDesktopUaPlatform(ua), DesktopUaPlatform.windows);
    });

    test('detects Linux via "X11; Linux"', () {
      const ua = 'Mozilla/5.0 (X11; Linux x86_64; rv:147.0) '
          'Gecko/20100101 Firefox/147.0';
      expect(inferDesktopUaPlatform(ua), DesktopUaPlatform.linux);
    });

    test('falls back to Linux for unrecognized UAs', () {
      // "Something custom" — no platform markers. Linux is the safest
      // desktop fallback (matches Chrome-for-Android's "Request desktop
      // site" default).
      expect(inferDesktopUaPlatform('Mozilla/5.0 SomeBrowser/1.0'),
          DesktopUaPlatform.linux);
    });
  });

  group('navigatorPlatformFor', () {
    test('emits the values real Firefox/Chrome desktop emit', () {
      expect(navigatorPlatformFor(DesktopUaPlatform.linux), 'Linux x86_64');
      expect(navigatorPlatformFor(DesktopUaPlatform.macos), 'MacIntel');
      expect(navigatorPlatformFor(DesktopUaPlatform.windows), 'Win32');
    });
  });

  group('Firefox desktop UA constants', () {
    test('each canonical UA classifies as desktop and infers its platform', () {
      expect(isDesktopUserAgent(firefoxLinuxDesktopUserAgent), isTrue);
      expect(inferDesktopUaPlatform(firefoxLinuxDesktopUserAgent),
          DesktopUaPlatform.linux);

      expect(isDesktopUserAgent(firefoxMacosDesktopUserAgent), isTrue);
      expect(inferDesktopUaPlatform(firefoxMacosDesktopUserAgent),
          DesktopUaPlatform.macos);

      expect(isDesktopUserAgent(firefoxWindowsDesktopUserAgent), isTrue);
      expect(inferDesktopUaPlatform(firefoxWindowsDesktopUserAgent),
          DesktopUaPlatform.windows);
    });
  });
}
