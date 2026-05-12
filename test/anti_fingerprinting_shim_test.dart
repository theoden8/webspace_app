import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/anti_fingerprinting_shim.dart';

void main() {
  group('buildAntiFingerprintingShim', () {
    final js = buildAntiFingerprintingShim('alpha-fixture-seed');

    test('runs as an IIFE so locals do not leak to the global scope', () {
      expect(js.trim(), startsWith('(function() {'));
      expect(js.trim(), endsWith('})();'));
    });

    test('installs a re-entrance guard so re-runs do not double-wrap', () {
      // Android System WebView and WKWebView both re-run initialUserScripts
      // on every frame load. Without the guard, every wrapper would wrap
      // its previous wrapping and amplify the noise per frame.
      expect(js, contains('__ws_anti_fp_shim__'));
    });

    test('shares __wsFnStubs with desktop_mode / location_spoof', () {
      // All three privacy shims funnel `Function.prototype.toString`
      // through one patched implementation keyed off this WeakMap, so
      // a fingerprinter probing toString sees `[native code]` for every
      // wrapped method regardless of which shim wrapped it.
      expect(js, contains('__wsFnStubs'));
      expect(js, contains('__wsFnToStringPatched'));
      expect(js, contains('Function.prototype.toString'));
    });

    test('seed flows into the FNV-1a + Mulberry32 PRNG', () {
      expect(js, contains('"alpha-fixture-seed"'));
      expect(js, contains('hashStr'));
      expect(js, contains('makeRng'));
    });

    test('different seeds produce different shim sources', () {
      // Two sites must see different fingerprints — the only difference
      // we control is the embedded seed string. Cross-site uniqueness
      // requires the source to differ.
      final other = buildAntiFingerprintingShim('beta-fixture-seed');
      expect(other, isNot(equals(js)));
      expect(other, contains('"beta-fixture-seed"'));
    });

    test('same seed reproduces the same shim (per-site stability)', () {
      // A given site must see the same fingerprint across launches —
      // builder must be a pure function of its seed.
      final again = buildAntiFingerprintingShim('alpha-fixture-seed');
      expect(again, equals(js));
    });

    test('patches Canvas 2D fingerprinting surfaces', () {
      expect(js, contains('CanvasRenderingContext2D'));
      expect(js, contains('getImageData'));
      expect(js, contains('toDataURL'));
      expect(js, contains('toBlob'));
    });

    test('patches WebGL fingerprinting surfaces', () {
      expect(js, contains('WebGLRenderingContext'));
      expect(js, contains('WebGL2RenderingContext'));
      expect(js, contains('getParameter'));
      expect(js, contains('getSupportedExtensions'));
      expect(js, contains('readPixels'));
      // UNMASKED_VENDOR_WEBGL = 37445, UNMASKED_RENDERER_WEBGL = 37446
      expect(js, contains('37445'));
      expect(js, contains('37446'));
      // GL_VENDOR = 7936, GL_RENDERER = 7937
      expect(js, contains('7936'));
      expect(js, contains('7937'));
    });

    test('patches Audio fingerprinting surfaces', () {
      expect(js, contains('AudioBuffer'));
      expect(js, contains('AnalyserNode'));
      expect(js, contains('getChannelData'));
      expect(js, contains('copyFromChannel'));
      expect(js, contains('getFloatFrequencyData'));
      expect(js, contains('getFloatTimeDomainData'));
    });

    test('patches text-metrics surfaces (Canvas + Offscreen)', () {
      expect(js, contains('measureText'));
      expect(js, contains('OffscreenCanvasRenderingContext2D'));
    });

    test('patches font enumeration', () {
      expect(js, contains('document.fonts'));
      expect(js, contains('check'));
    });

    test('overrides screen.* on Screen.prototype', () {
      // Defining on the prototype (not the instance) keeps the shim
      // invisible to `Object.getOwnPropertyNames(screen)`.
      expect(js, contains('Screen.prototype'));
      expect(js, contains("'width'"));
      expect(js, contains("'height'"));
      expect(js, contains("'availWidth'"));
      expect(js, contains("'availHeight'"));
      expect(js, contains("'colorDepth'"));
      expect(js, contains("'pixelDepth'"));
    });

    test('overrides hardware identifiers on Navigator.prototype', () {
      expect(js, contains('Navigator.prototype'));
      expect(js, contains("'hardwareConcurrency'"));
      expect(js, contains("'deviceMemory'"));
      expect(js, contains("'plugins'"));
      expect(js, contains("'mimeTypes'"));
    });

    test('overrides navigator.getBattery to a fixed-value Promise', () {
      expect(js, contains('getBattery'));
      expect(js, contains('Promise.resolve'));
    });

    test('overrides speechSynthesis.getVoices to []', () {
      expect(js, contains('SpeechSynthesis'));
      expect(js, contains('getVoices'));
    });

    test('quantizes performance.now and Date.now', () {
      // 100ms granularity defeats high-resolution-timer side channels
      // without breaking normal animation/loading code.
      expect(js, contains('performance.now'));
      expect(js, contains('Date.now'));
      expect(js, contains('100'));
    });

    test('jitters Element/Range bounding rects', () {
      expect(js, contains('Element.prototype'));
      expect(js, contains('Range.prototype'));
      expect(js, contains('getBoundingClientRect'));
    });

    test('wraps the body in try/catch so a missing API never breaks boot', () {
      // Rough proxy: the shim should have many try/catch blocks so a
      // thrown exception in one surface (e.g. AudioBuffer absent) does
      // not abort the rest of the patches.
      final tryCount = 'try {'.allMatches(js).length;
      expect(tryCount, greaterThanOrEqualTo(10));
    });

    test('asNative is applied so wrapped methods stringify as native', () {
      // Every wrapper goes through asNative(...) which records the
      // function in __wsFnStubs so Function.prototype.toString returns
      // the [native code] stub. Detection of the override via toString
      // probes is what asNative is there to defeat.
      expect(js, contains('asNative('));
      expect(js, contains('[native code]'));
    });
  });

  group('computeAntiFingerprintingSeed', () {
    // Issue #327 / ETP-019: incognito sites must randomize their
    // fingerprint per launch, while non-incognito sites keep the
    // ETP-004 stable-per-site posture.

    test('non-incognito returns siteId verbatim', () {
      final seed = computeAntiFingerprintingSeed(
        siteId: 'site-A',
        incognito: false,
        launchNonce: 'nonce-1',
      );
      expect(seed, equals('site-A'));
    });

    test('non-incognito ignores the launch nonce entirely', () {
      // Stable per-site fingerprint across launches: same siteId, two
      // different launches, same seed.
      final s1 = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: false, launchNonce: 'nonce-1',
      );
      final s2 = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: false, launchNonce: 'nonce-2',
      );
      expect(s1, equals(s2));
    });

    test('incognito mixes in the nonce', () {
      final seed = computeAntiFingerprintingSeed(
        siteId: 'site-A',
        incognito: true,
        launchNonce: 'nonce-1',
      );
      expect(seed, isNot(equals('site-A')));
      expect(seed, contains('site-A'));
      expect(seed, contains('nonce-1'));
    });

    test('incognito + same (siteId, nonce) -> same seed (in-session stability)',
        () {
      // Same fingerprint across iframe re-injection within one app
      // session — flicker would itself be a fingerprintable signal.
      final s1 = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-1',
      );
      final s2 = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-1',
      );
      expect(s1, equals(s2));
    });

    test('incognito + different nonces -> different seeds (per-launch reroll)',
        () {
      final s1 = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-1',
      );
      final s2 = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-2',
      );
      expect(s1, isNot(equals(s2)));
    });

    test('incognito + different siteIds, same nonce -> different seeds', () {
      // Two incognito tabs in the same launch must still see distinct
      // fingerprints (cross-site uniqueness, ETP-004).
      final a = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-1',
      );
      final b = computeAntiFingerprintingSeed(
        siteId: 'site-B', incognito: true, launchNonce: 'nonce-1',
      );
      expect(a, isNot(equals(b)));
    });

    test('toggling incognito for the same site changes the seed', () {
      // The whole point of issue #327: the user enabled incognito to opt
      // out of the stable identity, so the seed MUST differ from the
      // non-incognito case.
      final stable = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: false, launchNonce: 'nonce-1',
      );
      final ephemeral = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-1',
      );
      expect(ephemeral, isNot(equals(stable)));
    });

    test('seed flows through buildAntiFingerprintingShim end-to-end', () {
      // Sanity: the seed string we compute appears in the generated
      // shim source, so the JS-side PRNG is keyed off the right value.
      final seed = computeAntiFingerprintingSeed(
        siteId: 'site-A', incognito: true, launchNonce: 'nonce-1',
      );
      final shim = buildAntiFingerprintingShim(seed);
      expect(shim, contains('"site-A:nonce-1"'));
    });
  });
}
