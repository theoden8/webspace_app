import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/settings/location.dart';

void main() {
  group('LocationSpoofService', () {
    test('off mode blocks instead of passing through to the platform', () {
      // LOC-OFF-001. `off` used to emit no shim at all, which left the
      // platform's own navigator.geolocation in place: on iOS/macOS/Linux a
      // page could still obtain the real fix through the webview's own
      // permission prompt, so the least-permissive-looking option was the
      // only pass-through one. It now refuses every request on every
      // platform.
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.off,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, contains('var BLOCK_LOC = true'));
      expect(script, contains('var STATIC_LOC = false'));
      expect(script, contains('var LIVE_LOC = false'));
      expect(script, contains('function deniedError()'));
    });

    test('spoof mode without coordinates fails closed', () {
      // LOC-OFF-002. Reachable from a hand-edited or partially-restored
      // backup. Emitting no shim would hand the page the real device fix,
      // which is the opposite of what the site is configured for.
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, contains('var BLOCK_LOC = true'));
      expect(script, contains('var STATIC_LOC = false'));
    });

    test('an explicit grant never sets BLOCK_LOC', () {
      for (final grant in [
        (LocationMode.live, null, null),
        (LocationMode.spoof, 35.6762, 139.6503),
      ]) {
        final script = LocationSpoofService.buildScript(
          locationMode: grant.$1,
          spoofLatitude: grant.$2,
          spoofLongitude: grant.$3,
          spoofAccuracy: 50.0,
          spoofTimezone: null,
          webRtcPolicy: WebRtcPolicy.defaultPolicy,
        );
        expect(script, contains('var BLOCK_LOC = false'),
            reason: '${grant.$1} is a grant and must not block');
      }
    });

    test('live mode emits a shim that flips LIVE_LOC and not STATIC_LOC', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.live,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      // STATIC_LOC must be false — the shim should not embed any static
      // coords. LIVE_LOC must be true so the JS code path calls back into
      // Dart for fresh fixes via flutter_inappwebview.callHandler.
      expect(script, contains('var STATIC_LOC = false'));
      expect(script, contains('var LIVE_LOC = true'));
      expect(script, contains("callHandler('getRealLocation')"));
    });

    test('geolocation shim embeds the coordinates', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: 35.6762,
        spoofLongitude: 139.6503,
        spoofAccuracy: 25.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      expect(script, contains('var STATIC_LOC = true'));
      expect(script, contains('var LAT = 35.6762'));
      expect(script, contains('var LNG = 139.6503'));
      expect(script, contains('var ACC = 25.0'));
      expect(script, contains('var TZ = null'));
      expect(script, contains('var WRTC = "default"'));
    });

    test('timezone-only shim still emits script without static_loc', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.off,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: 'Asia/Tokyo',
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      expect(script, contains('var STATIC_LOC = false'));
      expect(script, contains('var TZ = "Asia/Tokyo"'));
    });

    test('webrtc relay-only shim sets WRTC=relay', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.off,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.relayOnly,
      );
      expect(script, isNotNull);
      expect(script, contains('var WRTC = "relay"'));
      expect(script, contains("iceTransportPolicy = 'relay'"));
      expect(script, contains('typ relay'));
    });

    test('webrtc disabled shim sets WRTC=off and neuters RTCPeerConnection', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.off,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.disabled,
      );
      expect(script, isNotNull);
      expect(script, contains('var WRTC = "off"'));
      expect(script, contains('WebRTC disabled'));
    });

    test('shim patches prototype methods not just instance', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: 0.0,
        spoofLongitude: 0.0,
        spoofAccuracy: 50.0,
        spoofTimezone: 'UTC',
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, contains('Geolocation.prototype'));
      expect(script, contains('Date.prototype.getTimezoneOffset'));
      expect(script, contains('Date.prototype.toString'));
      expect(script, contains('Intl.DateTimeFormat'));
    });

    test('shim hardens Function.prototype.toString', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: 0.0,
        spoofLongitude: 0.0,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, contains('Function.prototype.toString'));
      expect(script, contains('[native code]'));
    });

    test('shim fakes permissions.query for geolocation', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: 0.0,
        spoofLongitude: 0.0,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, contains('navigator.permissions'));
      expect(script, contains("name === 'geolocation'"));
      expect(script, contains("'granted'"));
    });

    test('live mode without granularity defaults to gps (no snap)', () {
      // Backwards-compat: callers that omit `liveLocationGranularity`
      // must still build a live shim that does NOT snap — snapping is
      // opt-in only via approximate/gsm.
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.live,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      expect(script, contains('var LIVE_LOC = true'));
      expect(script, contains('var SNAP_STEP_DEG = 0.0'));
      expect(script, contains('var SNAP_MIN_ACC_M = 0.0'));
    });

    test('live mode with approximate granularity snaps to a ~110 m grid', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.live,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        liveLocationGranularity: LocationGranularity.approximate,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      expect(script, contains('var LIVE_LOC = true'));
      expect(script, contains('var SNAP_STEP_DEG = 0.001'));
      expect(script, contains('var SNAP_MIN_ACC_M = 110.0'));
      // Grid snapping logic must be present in the live-mode shim.
      expect(script, contains('snapFix'));
    });

    test('live mode with gsm granularity snaps to a ~1.1 km grid', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.live,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        liveLocationGranularity: LocationGranularity.gsm,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      expect(script, contains('var LIVE_LOC = true'));
      expect(script, contains('var SNAP_STEP_DEG = 0.01'));
      expect(script, contains('var SNAP_MIN_ACC_M = 1100.0'));
      expect(script, contains('snapFix'));
    });

    test('granularity is ignored for spoof mode (static coords are user-chosen)', () {
      // Static spoof coords reflect what the user typed/picked; the
      // builder must not flip on snapping when the mode isn't live, even
      // if the caller passes gsm.
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: 35.6762,
        spoofLongitude: 139.6503,
        spoofAccuracy: 25.0,
        spoofTimezone: null,
        liveLocationGranularity: LocationGranularity.gsm,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNotNull);
      expect(script, contains('var STATIC_LOC = true'));
      expect(script, contains('var LIVE_LOC = false'));
      expect(script, contains('var SNAP_STEP_DEG = 0.0'));
      expect(script, contains('var SNAP_MIN_ACC_M = 0.0'));
    });

    test('installs only once via window flag', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: 1.0,
        spoofLongitude: 2.0,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, contains('__wsLocShimInstalled'));
    });
  });

  group('snapLiveFix (authoritative live-location granularity)', () {
    // The getRealLocation bridge handler applies this natively, so a page
    // calling callHandler('getRealLocation') directly can't bypass the
    // per-site granularity by skipping the JS shim's snapFix.
    const lat = 37.422131;
    const lng = -122.084801;

    test('gps tier does not alter the fix', () {
      final (a, b, c) = snapLiveFix(
        latitude: lat,
        longitude: lng,
        accuracy: 5.0,
        granularity: LocationGranularity.gps,
      );
      expect(a, lat);
      expect(b, lng);
      expect(c, 5.0);
    });

    test('approximate tier snaps to ~110 m grid and inflates accuracy', () {
      final (a, b, c) = snapLiveFix(
        latitude: lat,
        longitude: lng,
        accuracy: 5.0,
        granularity: LocationGranularity.approximate,
      );
      // Coordinates are coarsened (no longer full precision).
      expect(a, isNot(lat));
      expect(b, isNot(lng));
      // Snapped latitude lands on the 0.001-degree grid.
      expect((a / 0.001 - (a / 0.001).roundToDouble()).abs(), lessThan(1e-9));
      // Reported accuracy floored to the tier minimum.
      expect(c, greaterThanOrEqualTo(110.0));
      // The coarsening is real: within ~1 grid cell of the true point.
      expect((a - lat).abs(), lessThan(0.001));
    });

    test('gsm tier snaps to ~1.1 km grid and inflates accuracy', () {
      final (a, b, c) = snapLiveFix(
        latitude: lat,
        longitude: lng,
        accuracy: 5.0,
        granularity: LocationGranularity.gsm,
      );
      expect(c, greaterThanOrEqualTo(1100.0));
      expect((a / 0.01 - (a / 0.01).roundToDouble()).abs(), lessThan(1e-9));
    });

    test('a high-accuracy fix cannot leak through a coarse tier', () {
      // Even a 1 m accuracy device fix is reported no better than the tier
      // floor after snapping.
      final (_, __, acc) = snapLiveFix(
        latitude: lat,
        longitude: lng,
        accuracy: 1.0,
        granularity: LocationGranularity.gsm,
      );
      expect(acc, greaterThanOrEqualTo(1100.0));
    });
  });
}
