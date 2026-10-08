import 'dart:math' as math;

import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/location.dart';

/// `(grid step in degrees, minimum reported accuracy in metres)` for a live
/// granularity tier. A zero step means no snapping (the `gps` tier). Single
/// source of truth for both the injected JS shim (`snapFix`) and the native
/// `getRealLocation` handler, so the two can't drift.
(double, double) liveSnapParams(LocationGranularity granularity) {
  switch (granularity) {
    case LocationGranularity.gps:
      return (0.0, 0.0);
    case LocationGranularity.approximate:
      return (0.001, 110.0);
    case LocationGranularity.gsm:
      return (0.01, 1100.0);
  }
}

/// Snap a live device fix to the tier's grid and inflate its reported
/// accuracy, mirroring the JS shim's `snapFix`. This MUST also be applied
/// natively before the fix leaves Dart: the geolocation shim is injected
/// `forMainFrameOnly: false`, so a page (or cross-origin iframe) can call
/// `callHandler('getRealLocation')` directly and skip the JS snapping. Doing
/// the reduction here makes the per-site granularity authoritative regardless
/// of how the page reaches the bridge. Returns `(latitude, longitude,
/// accuracy)`.
(double, double, double) snapLiveFix({
  required double latitude,
  required double longitude,
  required double accuracy,
  required LocationGranularity granularity,
}) {
  final (stepDeg, minAccM) = liveSnapParams(granularity);
  if (!(stepDeg > 0)) {
    return (latitude, longitude, accuracy);
  }
  final snappedLat = (latitude / stepDeg).roundToDouble() * stepDeg;
  // Longitude step derived from the snapped latitude so cells stay roughly
  // square toward the poles; guard the polar cos->0 singularity.
  final cosLat = math.cos(snappedLat * math.pi / 180);
  final lngStep = stepDeg / math.max(cosLat.abs(), 1e-6);
  final snappedLng = (longitude / lngStep).roundToDouble() * lngStep;
  final inflated = math.max(accuracy, minAccM);
  return (snappedLat, snappedLng, inflated);
}

/// The location shim, described in lib/js/location_spoof.js: geolocation,
/// timezone and WebRTC policy for one site.
class LocationSpoofService {
  /// Whether [buildScript]'s output changes anything a worker global scope
  /// can observe. Geolocation is absent from `WorkerNavigator` and the
  /// WebRTC half is explicitly window-only, so the timezone override is the
  /// only half that survives there. Propagating the shim without one buys a
  /// worker nothing and costs the blob indirection (WORK-006).
  static bool affectsWorkerScope(String? spoofTimezone) =>
      spoofTimezone != null && spoofTimezone.isNotEmpty;

  /// Build the shim. Always returns a script: geolocation is mediated in
  /// every mode, including [LocationMode.off], which refuses the page rather
  /// than deferring to the platform.
  static String buildScript(SiteLocation location) {
    final (
      :mode,
      :latitude,
      :longitude,
      :accuracy,
      :timezone,
      :granularity,
      :webRtc,
    ) = location;
    final spoofLocation =
        mode == LocationMode.spoof && latitude != null && longitude != null;
    final liveLocation = mode == LocationMode.live;
    // Anything that is not an explicit grant refuses the page. Without a shim
    // the platform's own `navigator.geolocation` stays live behind the
    // webview's permission prompt, so [LocationMode.off] used to be the only
    // pass-through option while reading as the least permissive one. A
    // [LocationMode.spoof] site whose coordinates went missing (hand-edited
    // backup, failed import) fails closed for the same reason.
    final blockLocation = !spoofLocation && !liveLocation;
    final hasTimezone = timezone != null && timezone.isNotEmpty;

    // Snap step (degrees) and accuracy floor (metres) chosen per tier.
    // 0.001° ≈ 110 m at the equator; 0.01° ≈ 1100 m. GPS=no snap. The
    // longitude step is derived from cos(snappedLat) at runtime so cells
    // stay roughly square at higher latitudes (see snapFix in the script).
    final (snapStepDeg, snapMinAccM) = !liveLocation
        ? (0.0, 0.0)
        : liveSnapParams(granularity);

    return PageJs.locationSpoof.withConfig({
      'staticLocation': spoofLocation,
      'liveLocation': liveLocation,
      'blockLocation': blockLocation,
      'snapStepDeg': snapStepDeg,
      'snapMinAccM': snapMinAccM,
      'latitude': latitude ?? 0.0,
      'longitude': longitude ?? 0.0,
      'accuracy': accuracy > 0 ? accuracy : kDefaultSpoofAccuracy,
      'timezone': hasTimezone ? timezone : null,
      'webRtc': switch (webRtc) {
        WebRtcPolicy.relayOnly => 'relay',
        WebRtcPolicy.disabled => 'off',
        WebRtcPolicy.defaultPolicy => 'default',
      },
    });
  }
}
