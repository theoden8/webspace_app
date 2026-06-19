/// Whether a site derives its spoofed timezone from its (spoofed) coordinates
/// rather than an explicit zone.
///
/// True when coordinates are set AND either the user picked "From picked
/// location" or Tracking Protection forces it (TP pins the timezone to the
/// spoofed geo so Date/Intl match). Single source of truth for the three
/// places that must agree, or a site's timezone silently stops being spoofed:
///   - settings-save baking the resolved zone into `spoofTimezone`,
///   - the cold-start synchronous resolve for an unbaked launched site,
///   - the post-paint background re-bake migration.
/// Pure (no Flutter, no I/O) — see test/timezone_spoof_policy_test.dart.
library;

bool derivesTimezoneFromLocation({
  required bool spoofTimezoneFromLocation,
  required bool trackingProtectionEnabled,
  required double? spoofLatitude,
  required double? spoofLongitude,
}) {
  final hasCoords = spoofLatitude != null && spoofLongitude != null;
  return hasCoords && (spoofTimezoneFromLocation || trackingProtectionEnabled);
}
