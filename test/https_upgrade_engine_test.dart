import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/https_upgrade_engine.dart';
import 'package:webspace/services/webview.dart' show WebViewFactory;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

void main() {
  late HttpsUpgradeEngine engine;

  setUp(() => engine = HttpsUpgradeEngine());

  String? up(String url, {bool enabled = true}) =>
      engine.upgradeFor(url, enabled: enabled);

  group('HTTPS-001 a plain-http main-frame navigation is retried over https', () {
    test('scheme swaps and nothing else moves', () {
      expect(up('http://example.com/login.php?a=1&b=2#x'),
          'https://example.com/login.php?a=1&b=2#x');
    });

    test('the reported case', () {
      expect(up('http://tivipanel.net/reseller/login.php'),
          'https://tivipanel.net/reseller/login.php');
    });

    test('an https URL is left alone', () {
      expect(up('https://example.com/'), isNull);
    });

    test('non-http schemes are left alone', () {
      for (final url in [
        'file:///import.html',
        'about:blank',
        'about:srcdoc',
        'data:text/html,x',
        'intent://scan/#Intent;scheme=zxing;end',
        'webspace://open?url=http%3A%2F%2Fexample.com',
        'javascript:void(0)',
      ]) {
        expect(up(url), isNull, reason: url);
      }
    });

    test('a hostless or unparseable URL is left alone', () {
      expect(up('http:///nohost'), isNull);
      expect(up(''), isNull);
    });

    test('disabled short-circuits before anything else', () {
      expect(up('http://example.com/', enabled: false), isNull);
    });
  });

  group('HTTPS-003 hosts that cannot be expected to serve TLS', () {
    test('IP literals, single-label names and .local are skipped', () {
      for (final url in [
        'http://192.168.1.10/',
        'http://10.0.0.1/admin',
        'http://127.0.0.1:80/',
        'http://[fd00::1]/',
        'http://localhost/',
        'http://nas/files',
        'http://printer.local/status',
        'http://HOST.LOCAL/status',
      ]) {
        expect(up(url), isNull, reason: url);
      }
    });

    test('a four-label name that is not an IP still upgrades', () {
      expect(up('http://a.b.c.example/'), 'https://a.b.c.example/');
      expect(up('http://999.1.1.1/'), 'https://999.1.1.1/');
    });

    test('a non-default port is left alone', () {
      expect(up('http://example.com:8080/app'), isNull);
    });

    test('an explicit default port upgrades and drops the port', () {
      expect(up('http://example.com:80/app'), 'https://example.com/app');
    });
  });

  group('HTTPS-002 a failed upgrade falls back silently, once per host', () {
    test('the fallback is the original URL', () {
      final upgraded = up('http://intranet.example/a')!;
      expect(engine.fallbackFor(upgraded), 'http://intranet.example/a');
    });

    test('the host is remembered, so later navigations are not upgraded', () {
      final upgraded = up('http://intranet.example/a')!;
      engine.fallbackFor(upgraded);

      expect(engine.isKnownHttpOnly('intranet.example'), isTrue);
      expect(up('http://intranet.example/other'), isNull);
      // Case-insensitively, and for the site's other paths.
      expect(up('http://INTRANET.EXAMPLE/'), isNull);
      // A different host is unaffected.
      expect(up('http://other.example/'), 'https://other.example/');
    });

    test('the fallback URL is not itself upgraded', () {
      final upgraded = up('http://intranet.example/a')!;
      final fallback = engine.fallbackFor(upgraded)!;
      expect(up(fallback), isNull);
    });

    test('a failure on a URL the engine never upgraded is not a fallback', () {
      // The site asked for https itself. Handing back an http URL here would
      // be a downgrade the engine invented.
      expect(engine.fallbackFor('https://example.com/'), isNull);
      expect(engine.isKnownHttpOnly('example.com'), isFalse);
    });

    test('a fallback is only served once per upgrade', () {
      final upgraded = up('http://intranet.example/a')!;
      expect(engine.fallbackFor(upgraded), isNotNull);
      expect(engine.fallbackFor(upgraded), isNull);
    });

    test('a success drops the in-flight entry', () {
      final upgraded = up('http://example.com/a')!;
      engine.recordUpgradeSuccess(upgraded);
      // A later unrelated failure on the same URL must not read as a fallback
      // to an http load that finished long ago.
      expect(engine.fallbackFor(upgraded), isNull);
      expect(engine.isKnownHttpOnly('example.com'), isFalse);
    });

    test('recordUpgradeFailure marks a host without an in-flight upgrade', () {
      engine.recordUpgradeFailure('Intranet.Example');
      expect(engine.isKnownHttpOnly('intranet.example'), isTrue);
      expect(up('http://intranet.example/'), isNull);
    });

    test('reset forgets both sets', () {
      final upgraded = up('http://intranet.example/a')!;
      engine.fallbackFor(upgraded);
      engine.reset();
      expect(engine.isKnownHttpOnly('intranet.example'), isFalse);
      expect(up('http://intranet.example/a'), isNotNull);
    });
  });

  // HTTPS-005 + ETP-028. The resolution order is three-valued and the getter
  // sits directly below `effectiveThirdPartyCookiesEnabled`, which the
  // umbrella forces the OTHER way. Copying that shape here would invert a
  // security default silently: nothing else in the suite reads this getter,
  // and a site would quietly go back to plaintext the moment its owner turned
  // Tracking Protection on.
  group('HTTPS-005 / ETP-028 the effective decision', () {
    final appDefault = WebViewFactory.httpsUpgradeEnabled;
    tearDown(() => WebViewFactory.httpsUpgradeEnabled = appDefault);

    WebViewModel site({bool? override, bool umbrella = false}) => WebViewModel(
          initUrl: 'https://example.com',
          httpsUpgradeEnabled: override,
          trackingProtectionEnabled: umbrella,
        );

    test('a site with no override follows the app-wide default', () {
      WebViewFactory.httpsUpgradeEnabled = true;
      expect(site().effectiveHttpsUpgradeEnabled, isTrue);
      WebViewFactory.httpsUpgradeEnabled = false;
      expect(site().effectiveHttpsUpgradeEnabled, isFalse);
    });

    test('an override wins over the app-wide default, both ways', () {
      WebViewFactory.httpsUpgradeEnabled = false;
      expect(site(override: true).effectiveHttpsUpgradeEnabled, isTrue);
      WebViewFactory.httpsUpgradeEnabled = true;
      expect(site(override: false).effectiveHttpsUpgradeEnabled, isFalse);
    });

    test('the umbrella forces it ON, never off', () {
      WebViewFactory.httpsUpgradeEnabled = false;
      expect(site(override: false, umbrella: true).effectiveHttpsUpgradeEnabled,
          isTrue,
          reason: 'ETP-028 forces the upgrade on; the third-party-cookie '
              'getter next to it forces OFF, and copying that shape here '
              'would move a site to cleartext for turning privacy ON');
    });

    test('turning the umbrella off restores the stored value, not false', () {
      WebViewFactory.httpsUpgradeEnabled = true;
      expect(site(override: true, umbrella: false).effectiveHttpsUpgradeEnabled,
          isTrue,
          reason: 'turning Tracking Protection off to debug a site must not '
              'be what moves it to plaintext');
    });

    test('the pref the default comes from is registered and on', () {
      expect(kExportedAppPrefs[kHttpsUpgradeEnabledKey], isTrue);
    });

    test('the per-site override round-trips through JSON', () {
      for (final v in [true, false, null]) {
        final json = site(override: v).toJson();
        expect(json['httpsUpgradeEnabled'], v);
        expect(WebViewModel.fromJson(json, null).httpsUpgradeEnabled, v);
      }
    });
  });
}
