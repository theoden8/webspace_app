// The location shim as the app builds it for each scenario the jsdom and
// browser tiers run. The derivation (which mode a site's settings mean, the
// snap tier, the fallbacks) is LocationSpoofService.buildScript's, pinned by
// test/location_spoof_test.dart.

const { pageJs } = require('./page_js');

// A site with location off: geolocation refused, no zone, default WebRTC.
const OFF = {
  staticLocation: false,
  liveLocation: false,
  blockLocation: true,
  snapStepDeg: 0,
  snapMinAccM: 0,
  latitude: 0,
  longitude: 0,
  accuracy: 50,
  timezone: null,
  webRtc: 'default',
};
const location = (config) => pageJs('location_spoof', { ...OFF, ...config });
const live = (snapStepDeg, snapMinAccM) =>
  location({ liveLocation: true, blockLocation: false, snapStepDeg, snapMinAccM });

module.exports = {
  location,
  STATIC_TOKYO: location({
    staticLocation: true, blockLocation: false,
    latitude: 35.6762, longitude: 139.6503, accuracy: 25,
  }),
  LIVE_GPS: live(0, 0),
  LIVE_APPROXIMATE: live(0.001, 110),
  LIVE_GSM: live(0.01, 1100),
  BLOCKED: location({}),
  // A spoof site whose coordinates went missing fails closed, as off does.
  SPOOF_WITHOUT_COORDS: location({}),
  TIMEZONE_ONLY_UTC: location({ timezone: 'UTC' }),
  TIMEZONE_ONLY_TOKYO: location({ timezone: 'Asia/Tokyo' }),
  WEBRTC_RELAY: location({ webRtc: 'relay' }),
  WEBRTC_DISABLED: location({ webRtc: 'off' }),
  FULL_COMBO: location({
    staticLocation: true, blockLocation: false,
    latitude: 48.8566, longitude: 2.3522, accuracy: 30,
    timezone: 'Europe/Paris', webRtc: 'relay',
  }),
};
