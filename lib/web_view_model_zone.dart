import 'package:webspace/services/timezone_location_service.dart';
import 'package:webspace/services/timezone_spoof_policy.dart';
import 'package:webspace/web_view_model.dart';

/// A site's zone where it takes it from its coordinates (LOC-010).
extension WebViewModelZone on WebViewModel {
  /// The zone comes from the coordinates and was never resolved: saved
  /// before tz-baking, or while the polygon dataset was absent.
  bool get zoneUnresolved =>
      (spoofTimezone?.isEmpty ?? true) &&
      derivesTimezoneFromLocation(
        spoofTimezoneFromLocation: spoofTimezoneFromLocation,
        trackingProtectionEnabled: trackingProtectionEnabled,
        spoofLatitude: spoofLatitude,
        spoofLongitude: spoofLongitude,
      );

  /// Whether a webview may be built for the site: its zone is its own, or a
  /// lookup has been tried, so a site without one runs at the system zone by
  /// the spec rather than because nothing looked. Its location shim takes
  /// the zone as the webview is built.
  bool get zoneLookedUp =>
      !zoneUnresolved || TimezoneLocationService.instance.lookedUp;
}

/// Resolves the zone of each of [sites] that takes it from its coordinates
/// and has none, where the dataset is on disk. One still without a zone runs
/// at the system one: the lookup was tried, and the dataset is absent or
/// covers none of its coordinates.
Future<void> resolveZones(Iterable<WebViewModel> sites) async {
  final unresolved = [
    for (final m in sites)
      if (m.zoneUnresolved) m,
  ];
  if (unresolved.isEmpty) return;
  final zones = TimezoneLocationService.instance;
  if (!await zones.loadFromCacheIfPresent()) return;
  for (final m in unresolved) {
    final tz = zones.lookup(m.spoofLatitude!, longitude: m.spoofLongitude!);
    if (tz != null) m.spoofTimezone = tz;
  }
}
