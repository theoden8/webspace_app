import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/do_not_track_shim.dart';

void main() {
  group('buildDoNotTrackShim', () {
    final js = buildDoNotTrackShim();

    test('overrides every DNT / GPC surface fingerprinters check', () {
      expect(js, contains("'doNotTrack'"));
      expect(js, contains("'msDoNotTrack'"));
      expect(js, contains("'globalPrivacyControl'"));
    });

    test('returns "1" for the DNT signals (opt-out per spec)', () {
      expect(js, contains("'1'"));
    });

    test('binds globalPrivacyControl to the boolean true (not the string)', () {
      // The shim funnels each surface through `defineGetter(obj, name,
      // value)`. globalPrivacyControl must be passed as a JS boolean so
      // `navigator.globalPrivacyControl === true` matches what real
      // browsers report; a string would fail strict-equality probes.
      expect(js, contains("'globalPrivacyControl', true"));
    });

    test('defines getters on Navigator.prototype, not the instance', () {
      // Defining the property on the navigator instance would leak it as
      // an own-property — fingerprinters can detect that. The shim must
      // hit Navigator.prototype so the property reads exactly like a
      // browser-native one.
      expect(js, contains('Navigator.prototype'));
    });

    test('wraps the body in try/catch so a missing API never breaks boot', () {
      expect(js, contains('try {'));
      expect(js, contains('catch'));
    });

    test('runs as an IIFE so locals do not leak to the global scope', () {
      expect(js.trim(), startsWith('(function() {'));
      expect(js.trim(), endsWith('})();'));
    });
  });
}
