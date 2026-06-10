import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// Serves a fixed body for the source-file URL and the product-details URL,
/// letting a test simulate either source succeeding/failing independently.
class _FakeFactory implements OutboundHttpFactory {
  final http.Response Function(Uri url) responder;
  _FakeFactory(this.responder);

  @override
  OutboundClient clientFor(UserProxySettings settings) =>
      OutboundClientReady(MockClient((req) async => responder(req.url)));
}

const _sourceUrl = 'hg.mozilla.org';
const _detailsUrl = 'product-details.mozilla.org';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final svc = FirefoxUserAgentService.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    svc.resetForTest();
  });

  tearDown(() {
    resetOutboundHttp();
    GlobalOutboundProxy.resetForTest();
    svc.resetForTest();
  });

  group('parseFirefoxVersionDisplay', () {
    test('plain release version', () {
      expect(parseFirefoxVersionDisplay('151.0'), 151);
    });
    test('point release keeps major', () {
      expect(parseFirefoxVersionDisplay('151.0.1'), 151);
    });
    test('esr suffix', () {
      expect(parseFirefoxVersionDisplay('140.3.0esr'), 140);
    });
    test('nightly alpha suffix', () {
      expect(parseFirefoxVersionDisplay('153.0a1'), 153);
    });
    test('trailing whitespace/newline', () {
      expect(parseFirefoxVersionDisplay('151.0\n'), 151);
    });
    test('non-numeric body rejected', () {
      expect(parseFirefoxVersionDisplay('<html>not found</html>'), isNull);
    });
    test('implausibly large integer rejected', () {
      expect(parseFirefoxVersionDisplay('99999.0'), isNull);
    });
  });

  group('parseFirefoxProductDetails', () {
    test('reads LATEST_FIREFOX_VERSION', () {
      expect(
        parseFirefoxProductDetails('{"LATEST_FIREFOX_VERSION":"160.0.2"}'),
        160,
      );
    });
    test('malformed JSON rejected', () {
      expect(parseFirefoxProductDetails('not json'), isNull);
    });
    test('missing key rejected', () {
      expect(parseFirefoxProductDetails('{"FIREFOX_ESR":"140.0"}'), isNull);
    });
  });

  group('UA rendering', () {
    test('default version matches the canonical constants', () {
      expect(svc.linuxDesktopUserAgent, firefoxLinuxDesktopUserAgent);
      expect(svc.macosDesktopUserAgent, firefoxMacosDesktopUserAgent);
      expect(svc.windowsDesktopUserAgent, firefoxWindowsDesktopUserAgent);
    });

    test('randomUserAgent renders the current version on every platform', () {
      // Walk every index deterministically via a stub RNG.
      for (var i = 0; i < svc.randomUserAgents.length; i++) {
        final ua = svc.randomUserAgent(_StubRandom(i));
        expect(ua, svc.randomUserAgents[i]);
        // Every shape carries the version (desktop/Android as Firefox/rv,
        // iOS as FxiOS).
        expect(ua, contains(svc.versionString));
      }
    });

    test('mobile UAs are realistic Firefox shapes and classify as mobile', () {
      final android = buildFirefoxAndroidUserAgent(svc.versionString);
      // Frozen OS token, version-matched Gecko trail (not desktop 20100101).
      expect(android, contains('Android 10; Mobile'));
      expect(android, contains('Gecko/${svc.versionString}'));
      expect(android, contains('Firefox/${svc.versionString}'));
      expect(isDesktopUserAgent(android), isFalse);

      final ios = buildFirefoxIosUserAgent(svc.versionString);
      // iOS forces WebKit: Safari-shaped with an FxiOS marker, no Gecko.
      expect(ios, contains('AppleWebKit/605.1.15'));
      expect(ios, contains('FxiOS/${svc.versionString}'));
      expect(ios, isNot(contains('Gecko/${svc.versionString}')));
      expect(isDesktopUserAgent(ios), isFalse);
    });

    test('random pool covers all five platforms', () {
      expect(svc.randomUserAgents, hasLength(5));
    });
  });

  group('refresh', () {
    test('adopts a newer version scraped from the source file', () async {
      outboundHttp = _FakeFactory((url) {
        if (url.host.contains(_sourceUrl)) return http.Response('160.0\n', 200);
        return http.Response('', 404);
      });
      final changed = await svc.refresh();
      expect(changed, isTrue);
      expect(svc.majorVersion, 160);
      expect(svc.linuxDesktopUserAgent, contains('rv:160.0'));
      // Persisted for next launch.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('firefox_ua_major_version'), 160);
    });

    test('falls back to product-details when source file 404s', () async {
      outboundHttp = _FakeFactory((url) {
        if (url.host.contains(_detailsUrl)) {
          return http.Response('{"LATEST_FIREFOX_VERSION":"162.0.1"}', 200);
        }
        return http.Response('', 404);
      });
      expect(await svc.refresh(), isTrue);
      expect(svc.majorVersion, 162);
    });

    test('keeps the bundled floor when scrape is older', () async {
      outboundHttp =
          _FakeFactory((_) => http.Response('120.0', 200));
      expect(await svc.refresh(), isFalse);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('keeps the floor when both sources fail', () async {
      outboundHttp = _FakeFactory((_) => http.Response('', 500));
      expect(await svc.refresh(), isFalse);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('rejects garbage that parses out of range', () async {
      outboundHttp =
          _FakeFactory((_) => http.Response('<!doctype html>500000', 200));
      expect(await svc.refresh(), isFalse);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('refreshIfStale skips when checked within the TTL', () async {
      var hits = 0;
      outboundHttp = _FakeFactory((_) {
        hits++;
        return http.Response('170.0', 200);
      });
      // First call scrapes.
      await svc.refreshIfStale();
      expect(hits, 1);
      expect(svc.majorVersion, 170);
      // Second call within TTL must not hit the network again.
      await svc.refreshIfStale();
      expect(hits, 1);
    });
  });
}

/// Returns a fixed index from [nextInt], for deterministic platform choice.
class _StubRandom implements Random {
  final int value;
  _StubRandom(this.value);

  @override
  int nextInt(int max) => value % max;

  @override
  double nextDouble() => 0;

  @override
  bool nextBool() => false;
}
