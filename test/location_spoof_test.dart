import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/settings/location.dart';

void main() {
  group('LocationSpoofService', () {
    test('returns null when everything is default', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.off,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNull);
    });

    test('returns null when spoof mode is on but coordinates are missing', () {
      final script = LocationSpoofService.buildScript(
        locationMode: LocationMode.spoof,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: null,
        webRtcPolicy: WebRtcPolicy.defaultPolicy,
      );
      expect(script, isNull);
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
}
