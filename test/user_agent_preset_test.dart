import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/firefox_user_agent_service.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_preset.dart';
import 'package:webspace/web_view_model.dart';

// The exact string observed in the wild on a device that generated its UA
// with a pre-#410 build: iPhone platform token inside the Gecko desktop
// grammar. No real browser sends this combination.
const _wildLegacyHybrid =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 15_7_3 like Mac OS X; rv:147.0) '
    'Gecko/20100101 Firefox/147.0';

void main() {
  final svc = FirefoxUserAgentService.instance;

  setUp(svc.resetForTest);
  tearDown(svc.resetForTest);

  group('renderUserAgentPreset ↔ recognizeGeneratedUserAgent', () {
    test('round-trips every preset at multiple versions', () {
      for (final preset in UserAgentPreset.values) {
        for (final version in ['120.0', '151.0', '152.0', '199.0']) {
          final ua = renderUserAgentPreset(preset, version);
          expect(recognizeGeneratedUserAgent(ua), preset,
              reason: 'render($preset, $version) = $ua');
        }
      }
    });

    test('preset names survive JSON round-trip', () {
      for (final preset in UserAgentPreset.values) {
        expect(userAgentPresetFromName(preset.name), preset);
      }
      expect(userAgentPresetFromName(null), isNull);
      expect(userAgentPresetFromName('chromeVintage'), isNull);
    });
  });

  group('recognizeGeneratedUserAgent on legacy generated shapes', () {
    test('pre-#410 iPhone/Gecko hybrid (observed in the wild)', () {
      expect(
          recognizeGeneratedUserAgent(_wildLegacyHybrid), UserAgentPreset.firefoxIos);
    });

    test('old macOS token with Chrome-grammar underscores', () {
      const ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7; rv:151.0) '
          'Gecko/20100101 Firefox/151.0';
      expect(recognizeGeneratedUserAgent(ua), UserAgentPreset.firefoxMacos);
    });

    test('old FxiOS shape with Safari/605.1.15 tail and OS 18_5', () {
      const ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) '
          'AppleWebKit/605.1.15 (KHTML, like Gecko) FxiOS/151.0 '
          'Mobile/15E148 Safari/605.1.15';
      expect(recognizeGeneratedUserAgent(ua), UserAgentPreset.firefoxIos);
    });

    test('pre-#410 Android shape with the desktop Gecko trail', () {
      const ua = 'Mozilla/5.0 (Android 16; Mobile; rv:151.0) '
          'Gecko/20100101 Firefox/151.0';
      expect(recognizeGeneratedUserAgent(ua), UserAgentPreset.firefoxAndroid);
    });
  });

  group('recognizeGeneratedUserAgent rejects non-generated strings', () {
    test('real browsers pass through as custom', () {
      const realUAs = [
        // Mobile Safari.
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
            'Mobile/15E148 Safari/604.1',
        // Desktop Chrome.
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
        // Mozilla's Gecko-on-iOS: same platform token as the legacy hybrid
        // but the Gecko trail equals the version — a real browser we must
        // not rewrite.
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X; rv:147.0) '
            'Gecko/147.0 Firefox/147.0',
      ];
      for (final ua in realUAs) {
        expect(recognizeGeneratedUserAgent(ua), isNull, reason: ua);
      }
    });

    test('hand-edited version mismatches are not claimed', () {
      const ua = 'Mozilla/5.0 (X11; Linux x86_64; rv:151.0) '
          'Gecko/20100101 Firefox/152.0';
      expect(recognizeGeneratedUserAgent(ua), isNull);
    });

    test('empty and arbitrary strings', () {
      expect(recognizeGeneratedUserAgent(''), isNull);
      expect(recognizeGeneratedUserAgent('MyBrowser/1.0'), isNull);
    });
  });

  group('isStockWebViewDefaultUserAgent', () {
    // The exact string observed in the wild (BUG-005): a WKWebView default
    // frozen into storage by the old settings-screen prefill+save path.
    const wkWebViewDefault =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) '
        'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';

    test('recognizes stock defaults at any OS version', () {
      const defaults = [
        wkWebViewDefault,
        // Older iOS.
        'Mozilla/5.0 (iPhone; CPU iPhone OS 16_2 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        // iPad.
        'Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        // macOS WKWebView: bare, no Version/ or Safari/ tail.
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko)',
        // Android System WebView: `; wv` token + frozen Version/4.0.
        'Mozilla/5.0 (Linux; Android 14; Pixel 7 Build/UQ1A.240105.004; wv) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 '
            'Chrome/137.0.7151.61 Mobile Safari/537.36',
        // WPE/GTK WebKit: Safari-shaped on X11/Linux.
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 '
            '(KHTML, like Gecko) Version/17.0 Safari/605.1.15',
      ];
      for (final ua in defaults) {
        expect(isStockWebViewDefaultUserAgent(ua), isTrue, reason: ua);
      }
    });

    test('does not claim real browsers or generated shapes', () {
      final notDefaults = [
        // Mobile Safari (Version/ + Safari/ tail).
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
            'Mobile/15E148 Safari/604.1',
        // Desktop Chrome on Linux (no Version/ token).
        'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/137.0.0.0 Safari/537.36',
        // Chrome on Android (no wv token).
        'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/137.0.7151.61 Mobile Safari/537.36',
        // Generated FxiOS.
        buildFirefoxIosUserAgent('152.0'),
        // Generated desktop.
        firefoxLinuxDesktopUserAgent,
        '',
        'MyBrowser/1.0',
      ];
      for (final ua in notDefaults) {
        expect(isStockWebViewDefaultUserAgent(ua), isFalse, reason: ua);
      }
    });

    test('frozen default clears to no-override on load (BUG-005)', () {
      final json = WebViewModel(initUrl: 'https://example.com').toJson()
        ..['userAgent'] = wkWebViewDefault;
      json.remove('uaPreset');
      final model = WebViewModel.fromJson(json, null);
      expect(model.userAgent, '');
      expect(model.uaPreset, isNull);
      expect(model.effectiveUserAgentOrNull, isNull);
    });

    test('setUserAgent drops stock defaults and the live default', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.setUserAgent(wkWebViewDefault);
      expect(model.userAgent, '');
      expect(model.uaPreset, isNull);

      model.defaultUserAgent = 'SomeEngine/9.9 CustomDefault';
      model.setUserAgent('SomeEngine/9.9 CustomDefault');
      expect(model.userAgent, '');

      model.setUserAgent('MyBrowser/1.0');
      expect(model.userAgent, 'MyBrowser/1.0');
    });
  });

  group('WebViewModel preset integration', () {
    Map<String, dynamic> baseJson() =>
        WebViewModel(initUrl: 'https://example.com').toJson();

    test('legacy stored UA heals on load and renders current version', () {
      final json = baseJson()..['userAgent'] = _wildLegacyHybrid;
      json.remove('uaPreset');
      final model = WebViewModel.fromJson(json, null);
      expect(model.uaPreset, UserAgentPreset.firefoxIos);
      expect(model.effectiveUserAgent,
          buildFirefoxIosUserAgent(svc.versionString));
      // The webview no longer sees the broken string.
      expect(model.effectiveUserAgentOrNull, isNot(_wildLegacyHybrid));
    });

    test('version-stale generated UA re-renders at the current version', () {
      final stale =
          renderUserAgentPreset(UserAgentPreset.firefoxLinux, '120.0');
      final model = WebViewModel.fromJson(baseJson()..['userAgent'] = stale, null);
      expect(model.uaPreset, UserAgentPreset.firefoxLinux);
      expect(model.effectiveUserAgent, contains('rv:${svc.versionString}'));
      expect(model.effectiveUserAgent, isNot(contains('120.0')));
    });

    test('explicit uaPreset in JSON wins over recognition', () {
      final json = baseJson()
        ..['userAgent'] = 'whatever the old build rendered'
        ..['uaPreset'] = 'firefoxWindows';
      final model = WebViewModel.fromJson(json, null);
      expect(model.uaPreset, UserAgentPreset.firefoxWindows);
      expect(model.effectiveUserAgent,
          buildFirefoxUserAgent(kFirefoxWindowsPlatformToken, svc.versionString));
    });

    test('unknown uaPreset name falls back to recognition', () {
      final json = baseJson()
        ..['userAgent'] = 'MyBrowser/1.0'
        ..['uaPreset'] = 'somethingFromANewerAppVersion';
      final model = WebViewModel.fromJson(json, null);
      expect(model.uaPreset, isNull);
      expect(model.effectiveUserAgent, 'MyBrowser/1.0');
    });

    test('custom UA is preserved verbatim and not exported as a preset', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.setUserAgent('MyBrowser/1.0');
      expect(model.uaPreset, isNull);
      expect(model.effectiveUserAgent, 'MyBrowser/1.0');
      expect(model.toJson().containsKey('uaPreset'), isFalse);
    });

    test('no UA override renders empty/null', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      expect(model.effectiveUserAgent, '');
      expect(model.effectiveUserAgentOrNull, isNull);
    });

    test('setUserAgent re-attaches the preset for generated text', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.setUserAgent(
          renderUserAgentPreset(UserAgentPreset.firefoxAndroid, svc.versionString));
      expect(model.uaPreset, UserAgentPreset.firefoxAndroid);
      model.setUserAgent('');
      expect(model.uaPreset, isNull);
    });

    test('toJson/fromJson round-trip is stable (idempotent migration)', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.setUserAgent(
          renderUserAgentPreset(UserAgentPreset.firefoxIos, svc.versionString));
      final once = WebViewModel.fromJson(model.toJson(), null);
      final twice = WebViewModel.fromJson(once.toJson(), null);
      expect(once.uaPreset, UserAgentPreset.firefoxIos);
      expect(twice.uaPreset, UserAgentPreset.firefoxIos);
      expect(twice.effectiveUserAgent, once.effectiveUserAgent);
    });
  });
}
