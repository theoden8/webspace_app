// Behavioural tests for the per-site location/timezone/WebRTC shim
// (lib/services/location_spoof_service.dart).
//
// Asserts the shim's *override layer*: that getTimezoneOffset, Intl.DTF,
// RTCPeerConnection etc. now report the spoofed values. jsdom does not
// run a real WebRTC stack, so we cannot prove the relay-only mode
// actually filters ICE candidates over the wire — only that the wrap
// is installed and forces the policy on construction. End-to-end relay
// proof belongs in a Playwright tier (see test/js_fixtures/README.md).

const test = require('node:test');
const assert = require('node:assert/strict');
const { loadShim } = require('./helpers/load_shim');

test('webrtc_disabled: new RTCPeerConnection() throws "WebRTC disabled"', () => {
  const dom = loadShim('location_spoof/webrtc_disabled.js');
  assert.throws(
    () => new dom.window.RTCPeerConnection(),
    /WebRTC disabled/,
  );
});

test('webrtc_relay: RTCPeerConnection construction forces iceTransportPolicy=relay', () => {
  // The shim wraps the real RTCPeerConnection constructor: any config
  // object passed in has `iceTransportPolicy: 'relay'` injected before
  // the underlying ctor is called. The wrapped instance is what the page
  // gets back, so reading `__config` on it shows the policy was forced.
  const dom = loadShim('location_spoof/webrtc_relay.js');
  const pc = new dom.window.RTCPeerConnection({});
  assert.equal(pc.__config.iceTransportPolicy, 'relay');
});

test('webrtc_relay: setLocalDescription strips non-relay ICE candidates from SDP', async () => {
  const dom = loadShim('location_spoof/webrtc_relay.js');
  const pc = new dom.window.RTCPeerConnection();
  const sdp = [
    'v=0',
    'a=candidate:1 1 UDP 2130706431 192.168.1.10 54400 typ host',
    'a=candidate:2 1 UDP 1694498815 203.0.113.5 54400 typ srflx',
    'a=candidate:3 1 UDP 41885439 198.51.100.20 54400 typ relay',
    'a=other-line',
  ].join('\r\n');
  await pc.setLocalDescription({ sdp });
  // Only the typ relay candidate (and non-candidate lines) should survive.
  assert.ok(!pc.__lastSdp.sdp.includes('typ host'));
  assert.ok(!pc.__lastSdp.sdp.includes('typ srflx'));
  assert.ok(pc.__lastSdp.sdp.includes('typ relay'));
  assert.ok(pc.__lastSdp.sdp.includes('a=other-line'));
});

test('timezone_only_tokyo: Intl.DateTimeFormat reports Asia/Tokyo without explicit timeZone', () => {
  const dom = loadShim('location_spoof/timezone_only_tokyo.js');
  const dtf = new dom.window.Intl.DateTimeFormat('en-US');
  assert.equal(dtf.resolvedOptions().timeZone, 'Asia/Tokyo');
});

test('timezone_only_tokyo: Intl.DateTimeFormat respects an explicit timeZone arg', () => {
  // The shim only forces TZ when the caller doesn't pass one — sites
  // that explicitly request UTC must still get UTC.
  const dom = loadShim('location_spoof/timezone_only_tokyo.js');
  const dtf = new dom.window.Intl.DateTimeFormat('en-US', { timeZone: 'UTC' });
  assert.equal(dtf.resolvedOptions().timeZone, 'UTC');
});

test('timezone_only_tokyo: Date.prototype.getTimezoneOffset returns -540 for Tokyo (UTC+9)', () => {
  const dom = loadShim('location_spoof/timezone_only_tokyo.js');
  const offset = new dom.window.Date('2026-06-15T12:00:00Z').getTimezoneOffset();
  // getTimezoneOffset is signed inverse: positive when local is BEHIND
  // UTC, negative when AHEAD. Tokyo is UTC+9 → -540 minutes.
  assert.equal(offset, -540);
});

test('static_tokyo: navigator.geolocation.getCurrentPosition resolves with spoofed coords', async () => {
  const dom = loadShim('location_spoof/static_tokyo.js');
  const pos = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  // Coords are jittered ~2m so we assert within a small tolerance, not
  // an exact match.
  assert.ok(Math.abs(pos.coords.latitude - 35.6762) < 0.001);
  assert.ok(Math.abs(pos.coords.longitude - 139.6503) < 0.001);
  assert.equal(pos.coords.accuracy, 25);
});

test('static_tokyo: spoofed position is instanceof GeolocationPosition', () => {
  // Detection hardening: real browsers return a GeolocationPosition
  // instance, so `pos instanceof GeolocationPosition` is true. The shim
  // builds spoofed positions on the real prototype to match.
  const dom = loadShim('location_spoof/static_tokyo.js');
  return new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition((pos) => {
      try {
        assert.ok(pos instanceof dom.window.GeolocationPosition);
        assert.ok(pos.coords instanceof dom.window.GeolocationCoordinates);
        resolve();
      } catch (e) {
        reject(e);
      }
    }, reject);
  });
});

test('full_combo: all four overrides install in the same realm', () => {
  // Smoke test that the combined shim doesn't fail to install one
  // override because a previous one threw — they're all independent and
  // wrapped in try/catch in the shim, but a regression here would mean
  // a syntax error or top-level throw broke the whole bundle.
  const dom = loadShim('location_spoof/full_combo.js');
  // Geolocation patched (Paris coords).
  return new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition((pos) => {
      try {
        assert.ok(Math.abs(pos.coords.latitude - 48.8566) < 0.001);
        // Timezone patched (Europe/Paris).
        const dtf = new dom.window.Intl.DateTimeFormat('en-US');
        assert.equal(dtf.resolvedOptions().timeZone, 'Europe/Paris');
        // WebRTC wrapped (relay-only).
        const pc = new dom.window.RTCPeerConnection({});
        assert.equal(pc.__config.iceTransportPolicy, 'relay');
        resolve();
      } catch (e) {
        reject(e);
      }
    }, reject);
  });
});
