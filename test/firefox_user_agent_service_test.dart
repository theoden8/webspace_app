import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/settings/app_prefs.dart';
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

/// Models a misconfigured proxy: every request blocks rather than leaking a
/// direct connection.
class _BlockedFactory implements OutboundHttpFactory {
  @override
  OutboundClient clientFor(UserProxySettings settings) =>
      const OutboundClientBlocked('blocked by test fake');
}

const _sourceUrl = 'raw.githubusercontent.com';
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
      // Pinned OS major, version-matched Gecko trail (not desktop 20100101).
      expect(android, contains('$kFirefoxAndroidOsToken; Mobile'));
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

    test('desktop UAs match the exact Firefox desktop grammar', () {
      final grammar = RegExp(
          r'^Mozilla/5\.0 \((X11; Linux x86_64|Windows NT 10\.0; Win64; x64|'
          r'Macintosh; Intel Mac OS X 10\.15); rv:(\d+\.\d+)\) '
          r'Gecko/20100101 Firefox/(\d+\.\d+)$');
      for (final ua in [
        svc.linuxDesktopUserAgent,
        svc.macosDesktopUserAgent,
        svc.windowsDesktopUserAgent,
      ]) {
        final m = grammar.firstMatch(ua);
        expect(m, isNotNull, reason: 'not real Firefox desktop grammar: $ua');
        expect(m!.group(2), m.group(3), reason: 'rv: must equal version: $ua');
      }
      // Firefox freezes macOS at "10.15" with dots; the underscore form is
      // Chrome/WebKit grammar and outs the string as fabricated.
      expect(svc.macosDesktopUserAgent, isNot(contains('10_15')));
    });

    test('FxiOS UA matches upstream firefox-ios shape exactly', () {
      final ios = buildFirefoxIosUserAgent(svc.versionString);
      expect(
        ios,
        matches(RegExp(
            r'^Mozilla/5\.0 \(iPhone; CPU iPhone OS \d+_\d+ like Mac OS X\) '
            r'AppleWebKit/605\.1\.15 \(KHTML, like Gecko\) '
            r'FxiOS/\d+\.\d+ Mobile/15E148 Safari/604\.1$')),
      );
    });

    test('no pool UA claims Apple hardware with the Gecko grammar', () {
      // x.com (and anything sniffing for in-app browsers) treats an
      // iPhone/iPad token without WebKit+Safari tokens as fake and bounces
      // it to x-safari-https://. No real browser sends that combination —
      // iOS mandates WebKit — so no generated UA may either.
      for (final ua in svc.randomUserAgents) {
        if (ua.contains('iPhone') || ua.contains('iPad')) {
          expect(ua, isNot(contains('rv:')), reason: ua);
          expect(ua, isNot(contains('Gecko/')), reason: ua);
          expect(ua, contains('AppleWebKit'), reason: ua);
          expect(ua, contains('Safari/'), reason: ua);
        }
      }
    });
  });

  group('refresh', () {
    test('adopts a newer version scraped from the source file', () async {
      outboundHttp = _FakeFactory((url) {
        if (url.host.contains(_sourceUrl)) return http.Response('160.0\n', 200);
        return http.Response('', 404);
      });
      expect(await svc.refresh(), FirefoxVersionRefreshResult.updated);
      expect(svc.majorVersion, 160);
      expect(svc.linuxDesktopUserAgent, contains('rv:160.0'));
      expect(svc.lastChecked, isNotNull);
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
      expect(await svc.refresh(), FirefoxVersionRefreshResult.updated);
      expect(svc.majorVersion, 162);
    });

    test('reports unchanged when scrape is not newer', () async {
      outboundHttp = _FakeFactory((_) => http.Response('120.0', 200));
      expect(await svc.refresh(), FirefoxVersionRefreshResult.unchanged);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('reports failed when both sources fail', () async {
      outboundHttp = _FakeFactory((_) => http.Response('', 500));
      expect(await svc.refresh(), FirefoxVersionRefreshResult.failed);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('fails on garbage that parses out of range', () async {
      outboundHttp =
          _FakeFactory((_) => http.Response('<!doctype html>500000', 200));
      expect(await svc.refresh(), FirefoxVersionRefreshResult.failed);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('blocked outbound proxy fails without leaking direct', () async {
      outboundHttp = _BlockedFactory();
      expect(await svc.refresh(), FirefoxVersionRefreshResult.failed);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });
  });

  group('maybeAutoRefresh', () {
    test('no network when the opt-in pref is off (default)', () async {
      var hits = 0;
      outboundHttp = _FakeFactory((_) {
        hits++;
        return http.Response('160.0', 200);
      });
      await svc.maybeAutoRefresh();
      expect(hits, 0);
      expect(svc.majorVersion, kDefaultFirefoxMajorVersion);
    });

    test('refreshes when opted in and never checked', () async {
      SharedPreferences.setMockInitialValues(
          {kFirefoxUaAutoRefreshKey: true});
      outboundHttp = _FakeFactory((_) => http.Response('160.0', 200));
      await svc.maybeAutoRefresh();
      expect(svc.majorVersion, 160);
    });

    test('throttles when checked within the interval', () async {
      SharedPreferences.setMockInitialValues({
        kFirefoxUaAutoRefreshKey: true,
        'firefox_ua_last_checked':
            DateTime.now().subtract(const Duration(days: 1)).toIso8601String(),
      });
      await svc.initialize();
      var hits = 0;
      outboundHttp = _FakeFactory((_) {
        hits++;
        return http.Response('160.0', 200);
      });
      await svc.maybeAutoRefresh();
      expect(hits, 0);
    });

    test('refreshes again once the interval has passed', () async {
      SharedPreferences.setMockInitialValues({
        kFirefoxUaAutoRefreshKey: true,
        'firefox_ua_last_checked': DateTime.now()
            .subtract(const Duration(days: 8))
            .toIso8601String(),
      });
      await svc.initialize();
      outboundHttp = _FakeFactory((_) => http.Response('160.0', 200));
      await svc.maybeAutoRefresh();
      expect(svc.majorVersion, 160);
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
