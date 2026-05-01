import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_metadata_builder.dart';

void main() {
  group('buildUserAgentMetadata', () {
    test('returns null for empty / null UA', () {
      // Empty UA → fall back to the platform default UA-CH metadata. We
      // explicitly DO NOT manufacture a fake brand list when the user has
      // not picked a UA, otherwise the wire-level UA-CH would lie about
      // a UA the user never chose.
      expect(buildUserAgentMetadata(null), isNull);
      expect(buildUserAgentMetadata(''), isNull);
    });

    group('mobile flag tracks the UA shape', () {
      test('Firefox desktop UA → mobile=false', () {
        // The whole point: a desktop-shaped UA must emit Sec-CH-UA-Mobile:?0
        // so DDG-style sites that gate on the header serve desktop.
        final m = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent);
        expect(m, isNotNull);
        expect(m!.mobile, isFalse);
      });

      test('Android Firefox UA → mobile=true', () {
        const ua = 'Mozilla/5.0 (Android 16; Mobile; rv:147.0) '
            'Gecko/20100101 Firefox/147.0';
        final m = buildUserAgentMetadata(ua);
        expect(m, isNotNull);
        expect(m!.mobile, isTrue);
      });

      test('iPhone UA → mobile=true', () {
        const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
            'Mobile/15E148 Safari/604.1';
        expect(buildUserAgentMetadata(ua)!.mobile, isTrue);
      });
    });

    group('platform tracks the UA platform', () {
      test('Linux Firefox → "Linux"', () {
        expect(buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!.platform,
            'Linux');
      });

      test('macOS Firefox → "macOS"', () {
        expect(buildUserAgentMetadata(firefoxMacosDesktopUserAgent)!.platform,
            'macOS');
      });

      test('Windows Firefox → "Windows"', () {
        expect(buildUserAgentMetadata(firefoxWindowsDesktopUserAgent)!.platform,
            'Windows');
      });

      test('Android Chrome → "Android"', () {
        const ua = 'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/137.0.0.0 '
            'Mobile Safari/537.36';
        expect(buildUserAgentMetadata(ua)!.platform, 'Android');
      });

      test('iPhone Safari → "iOS"', () {
        const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
            'Mobile/15E148 Safari/604.1';
        expect(buildUserAgentMetadata(ua)!.platform, 'iOS');
      });

      test('iPad Safari → "iOS"', () {
        const ua = 'Mozilla/5.0 (iPad; CPU OS 17_5 like Mac OS X) '
            'AppleWebKit/605.1.15';
        expect(buildUserAgentMetadata(ua)!.platform, 'iOS');
      });
    });

    group('brandVersionList is consistent with the UA string', () {
      test('Firefox UA → GREASE + Firefox brand with parsed version', () {
        final m = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
        final brands = m.brandVersionList!;
        // GREASE first to keep brand list shape unstable for fingerprinters.
        expect(brands.first.brand, 'Not.A/Brand');
        expect(brands.first.majorVersion, '99');
        // The actual brand entry must match the UA's Firefox version.
        final firefoxEntry =
            brands.firstWhere((b) => b.brand == 'Firefox');
        expect(firefoxEntry.majorVersion, '147');
      });

      test('Chrome UA → GREASE + Chromium + Google Chrome', () {
        const ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/137.0.6943.137 Safari/537.36';
        final brands = buildUserAgentMetadata(ua)!.brandVersionList!;
        // Both Chromium and Google Chrome are required — real Chrome
        // emits both, and a server checking "Chromium" presence would
        // notice if we shipped only "Google Chrome".
        expect(brands.any((b) => b.brand == 'Chromium'), isTrue);
        expect(brands.any((b) => b.brand == 'Google Chrome'), isTrue);
        for (final b in brands.where((b) => b.brand != 'Not.A/Brand')) {
          expect(b.majorVersion, '137');
          expect(b.fullVersion, '137.0.6943.137');
        }
      });

      test('non-Firefox/non-Chrome UA → null brand list', () {
        // A UA we cannot parse safely falls through to the platform default
        // brand list rather than manufacturing a fake brand identity.
        const ua = 'Mozilla/5.0 SomeCustomBrowser/1.0';
        expect(buildUserAgentMetadata(ua)!.brandVersionList, isNull);
      });

      test('full version is padded to four segments', () {
        // `Sec-CH-UA-Full-Version-List` carries 4-segment versions.
        // Firefox UAs only carry "147.0" — pad to "147.0.0.0" so we
        // don't ship a suspiciously short value.
        final m = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
        final firefoxEntry =
            m.brandVersionList!.firstWhere((b) => b.brand == 'Firefox');
        expect(firefoxEntry.fullVersion, '147.0.0.0');
        expect(m.fullVersion, '147.0.0.0');
      });
    });

    test('serializes through toMap', () {
      // The wire format the platform channel consumes — must round-trip,
      // since the Android side reads the same keys we write here.
      final m = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
      final map = m.toMap();
      expect(map['platform'], 'Linux');
      expect(map['mobile'], isFalse);
      final brands = map['brandVersionList'] as List;
      expect(brands.length, 2);
      final firefoxBrand = brands.firstWhere(
        (b) => (b as Map)['brand'] == 'Firefox',
      ) as Map;
      expect(firefoxBrand['majorVersion'], '147');
      expect(firefoxBrand['fullVersion'], '147.0.0.0');
    });

    test('returned UserAgentMetadata is not const-equal across calls', () {
      // Each call constructs a fresh BrandVersion list; this guards against
      // a refactor that swaps the GREASE entry to a singleton — caller code
      // could mutate the list (toMap iterates it) and we don't want to
      // share state across sites.
      final a = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
      final b = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
      expect(identical(a, b), isFalse);
      expect(identical(a.brandVersionList, b.brandVersionList), isFalse);
    });
  });

  group('UserAgentMetadata wire shape', () {
    test('matches the Android key names the fork patch reads', () {
      // The native side (InAppWebView.java buildUserAgentMetadata) reads
      // these exact map keys. Renaming any of them silently breaks the
      // override. Lock the wire format here so the test fails on rename
      // rather than at runtime on Android.
      final m = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
      final map = m.toMap();
      expect(map.keys, containsAll([
        'brandVersionList',
        'fullVersion',
        'platform',
        'mobile',
      ]));
    });

    test('BrandVersion uses brand/majorVersion/fullVersion keys', () {
      final m = buildUserAgentMetadata(firefoxLinuxDesktopUserAgent)!;
      final firstBrand = (m.toMap()['brandVersionList'] as List).first as Map;
      expect(firstBrand.keys,
          containsAll(['brand', 'majorVersion', 'fullVersion']));
    });
  });
}
