import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/settings/location.dart';

/// A site's location settings: off, nothing overridden, unless given.
SiteLocation _loc({
  LocationMode mode = LocationMode.off,
  double? lat,
  double? lng,
  double accuracy = 50.0,
  String? tz,
  LocationGranularity granularity = LocationGranularity.gps,
  WebRtcPolicy webRtc = WebRtcPolicy.defaultPolicy,
}) =>
    (
      mode: mode,
      latitude: lat,
      longitude: lng,
      accuracy: accuracy,
      timezone: tz,
      granularity: granularity,
      webRtc: webRtc,
    );

void main() {
  group('LocationSpoofService', () {
    for (final (name, location, needles) in <(String, SiteLocation, List<String>)>[
      // LOC-OFF-001. `off` used to emit no shim at all, which left the
      // platform's own navigator.geolocation in place: on iOS/macOS/Linux a
      // page could still obtain the real fix through the webview's own
      // permission prompt, so the least-permissive-looking option was the
      // only pass-through one. It now refuses every request on every
      // platform.
      ('off mode blocks instead of passing through to the platform', _loc(), [
        'var BLOCK_LOC = true',
        'var STATIC_LOC = false',
        'var LIVE_LOC = false',
        'function deniedError()',
      ]),
      // LOC-OFF-002. Reachable from a hand-edited or partially-restored
      // backup. Emitting no shim would hand the page the real device fix,
      // which is the opposite of what the site is configured for.
      ('spoof mode without coordinates fails closed',
          _loc(mode: LocationMode.spoof),
          ['var BLOCK_LOC = true', 'var STATIC_LOC = false']),
      // STATIC_LOC must be false — the shim should not embed any static
      // coords. LIVE_LOC must be true so the JS code path calls back into
      // Dart for fresh fixes via flutter_inappwebview.callHandler.
      ('live mode emits a shim that flips LIVE_LOC and not STATIC_LOC',
          _loc(mode: LocationMode.live), [
        'var STATIC_LOC = false',
        'var LIVE_LOC = true',
        "callHandler('getRealLocation')",
      ]),
      ('geolocation shim embeds the coordinates',
          _loc(mode: LocationMode.spoof, lat: 35.6762, lng: 139.6503,
              accuracy: 25.0), [
        'var STATIC_LOC = true',
        'var LAT = 35.6762',
        'var LNG = 139.6503',
        'var ACC = 25.0',
        'var TZ = null',
        'var WRTC = "default"',
      ]),
      ('timezone-only shim still emits script without static_loc',
          _loc(tz: 'Asia/Tokyo'),
          ['var STATIC_LOC = false', 'var TZ = "Asia/Tokyo"']),
      ('webrtc relay-only shim sets WRTC=relay',
          _loc(webRtc: WebRtcPolicy.relayOnly), [
        'var WRTC = "relay"',
        "iceTransportPolicy = 'relay'",
        'typ relay',
      ]),
      ('webrtc disabled shim sets WRTC=off and neuters RTCPeerConnection',
          _loc(webRtc: WebRtcPolicy.disabled),
          ['var WRTC = "off"', 'WebRTC disabled']),
      ('shim patches prototype methods not just instance',
          _loc(mode: LocationMode.spoof, lat: 0.0, lng: 0.0, tz: 'UTC'), [
        'Geolocation.prototype',
        'Date.prototype.getTimezoneOffset',
        'Date.prototype.toString',
        'Intl.DateTimeFormat',
      ]),
      // BUG-009 / ETP-025: `X.prototype = Native.prototype` takes the native
      // prototype object, whose own `constructor` still names the native
      // constructor. Leaving it means `RTCPeerConnection.prototype.constructor`
      // builds an unpolicied peer connection that gathers host candidates
      // outside the proxy, and `Intl.DateTimeFormat.prototype.constructor`
      // resolves the device timezone.
      ('relay wrapper re-points RTCPeerConnection.prototype.constructor',
          _loc(webRtc: WebRtcPolicy.relayOnly), [
        '_Patched.prototype = _RealRTC.prototype',
        "Object.defineProperty(_Patched.prototype, 'constructor'",
        'value: _Patched',
      ]),
      ('timezone wrapper re-points DateTimeFormat.prototype.constructor',
          _loc(tz: 'Asia/Tokyo'), [
        'PatchedDTF.prototype = _nativeDTF.prototype',
        "Object.defineProperty(PatchedDTF.prototype, 'constructor'",
        'value: PatchedDTF',
      ]),
      ('shim hardens Function.prototype.toString',
          _loc(mode: LocationMode.spoof, lat: 0.0, lng: 0.0),
          ['Function.prototype.toString', '[native code]']),
      ('shim fakes permissions.query for geolocation',
          _loc(mode: LocationMode.spoof, lat: 0.0, lng: 0.0), [
        'navigator.permissions',
        "name === 'geolocation'",
        "'granted'",
      ]),
      // Backwards-compat: callers that omit `liveLocationGranularity`
      // must still build a live shim that does NOT snap — snapping is
      // opt-in only via approximate/gsm.
      ('live mode without granularity defaults to gps (no snap)',
          _loc(mode: LocationMode.live), [
        'var LIVE_LOC = true',
        'var SNAP_STEP_DEG = 0.0',
        'var SNAP_MIN_ACC_M = 0.0',
      ]),
      // `snapFix` is the grid snapping in the live-mode shim.
      ('live mode with approximate granularity snaps to a ~110 m grid',
          _loc(mode: LocationMode.live,
              granularity: LocationGranularity.approximate), [
        'var LIVE_LOC = true',
        'var SNAP_STEP_DEG = 0.001',
        'var SNAP_MIN_ACC_M = 110.0',
        'snapFix',
      ]),
      ('live mode with gsm granularity snaps to a ~1.1 km grid',
          _loc(mode: LocationMode.live, granularity: LocationGranularity.gsm),
          [
        'var LIVE_LOC = true',
        'var SNAP_STEP_DEG = 0.01',
        'var SNAP_MIN_ACC_M = 1100.0',
        'snapFix',
      ]),
      // Static spoof coords reflect what the user typed/picked; the
      // builder must not flip on snapping when the mode isn't live, even
      // if the caller passes gsm.
      ('granularity is ignored for spoof mode (static coords are user-chosen)',
          _loc(mode: LocationMode.spoof, lat: 35.6762, lng: 139.6503,
              accuracy: 25.0, granularity: LocationGranularity.gsm), [
        'var STATIC_LOC = true',
        'var LIVE_LOC = false',
        'var SNAP_STEP_DEG = 0.0',
        'var SNAP_MIN_ACC_M = 0.0',
      ]),
      ('installs only once via window flag',
          _loc(mode: LocationMode.spoof, lat: 1.0, lng: 2.0),
          ['__wsLocShimInstalled']),
    ]) {
      test(name, () {
        final script = LocationSpoofService.buildScript(location);
        for (final needle in needles) {
          expect(script, contains(needle));
        }
      });
    }

    test('an explicit grant never sets BLOCK_LOC', () {
      for (final grant in [
        (LocationMode.live, null, null),
        (LocationMode.spoof, 35.6762, 139.6503),
      ]) {
        final script = LocationSpoofService.buildScript(
            _loc(mode: grant.$1, lat: grant.$2, lng: grant.$3));
        expect(script, contains('var BLOCK_LOC = false'),
            reason: '${grant.$1} is a grant and must not block');
      }
    });
  });

  group('snapLiveFix (authoritative live-location granularity)', () {
    // The getRealLocation bridge handler applies this natively, so a page
    // calling callHandler('getRealLocation') directly can't bypass the
    // per-site granularity by skipping the JS shim's snapFix.
    const lat = 37.422131;
    const lng = -122.084801;
    (double, double, double) snap(LocationGranularity granularity,
            {double accuracy = 5.0}) =>
        snapLiveFix(
          latitude: lat,
          longitude: lng,
          accuracy: accuracy,
          granularity: granularity,
        );

    test('gps tier does not alter the fix', () {
      final (a, b, c) = snap(LocationGranularity.gps);
      expect(a, lat);
      expect(b, lng);
      expect(c, 5.0);
    });

    test('approximate tier snaps to ~110 m grid and inflates accuracy', () {
      final (a, b, c) = snap(LocationGranularity.approximate);
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
      final (a, _, c) = snap(LocationGranularity.gsm);
      expect(c, greaterThanOrEqualTo(1100.0));
      expect((a / 0.01 - (a / 0.01).roundToDouble()).abs(), lessThan(1e-9));
    });

    test('a high-accuracy fix cannot leak through a coarse tier', () {
      // Even a 1 m accuracy device fix is reported no better than the tier
      // floor after snapping.
      final (_, _, acc) = snap(LocationGranularity.gsm, accuracy: 1.0);
      expect(acc, greaterThanOrEqualTo(1100.0));
    });
  });
}
