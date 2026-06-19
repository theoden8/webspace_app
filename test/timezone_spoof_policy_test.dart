// Parity guard for derivesTimezoneFromLocation.
//
// Three sites must agree on "does this site derive its tz from coordinates",
// or a site's timezone silently stops being spoofed: settings-save baking,
// the cold-start launched-site resolve, and the background re-bake migration.
// They now share this function; these tests pin its truth table.
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';

void main() {
  group('derivesTimezoneFromLocation', () {
    bool f({
      bool fromLocation = false,
      bool tp = false,
      double? lat,
      double? lng,
    }) =>
        derivesTimezoneFromLocation(
          spoofTimezoneFromLocation: fromLocation,
          trackingProtectionEnabled: tp,
          spoofLatitude: lat,
          spoofLongitude: lng,
        );

    test('false without coordinates, even if requested', () {
      expect(f(fromLocation: true), isFalse);
      expect(f(tp: true), isFalse);
      expect(f(fromLocation: true, lat: 51.5), isFalse); // lng missing
      expect(f(tp: true, lng: -0.1), isFalse); // lat missing
    });

    test('explicit from-location with coords -> true', () {
      expect(f(fromLocation: true, lat: 51.5, lng: -0.1), isTrue);
    });

    test('tracking protection forces it when coords are set', () {
      expect(f(tp: true, lat: 35.6, lng: 139.7), isTrue);
      // TP alone, no coords -> false (umbrella only pins tz when geo is spoofed)
      expect(f(tp: true), isFalse);
    });

    test('coords set but neither flag -> false', () {
      expect(f(lat: 0.0, lng: 0.0), isFalse);
    });

    test('either flag with coords -> true (settings/migration/cold-start agree)',
        () {
      for (final fromLoc in [false, true]) {
        for (final tp in [false, true]) {
          final expected = fromLoc || tp;
          expect(f(fromLocation: fromLoc, tp: tp, lat: 1.0, lng: 2.0), expected);
        }
      }
    });
  });
}
