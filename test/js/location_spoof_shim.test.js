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

// Helper: install a fake flutter_inappwebview.callHandler that resolves
// every `getRealLocation` call with the same fix. Returns the dom so the
// caller can drive geolocation calls.
function loadLiveShim(fixtureRelPath, fakeFix) {
  const { loadShim: load } = require('./helpers/load_shim');
  const dom = load(fixtureRelPath);
  dom.window.flutter_inappwebview = {
    callHandler(name, ...args) {
      if (name === 'getRealLocation') {
        return Promise.resolve({
          status: 'ok',
          latitude: fakeFix.lat,
          longitude: fakeFix.lng,
          accuracy: fakeFix.acc,
        });
      }
      return Promise.resolve(null);
    },
  };
  return dom;
}

test('live_fine: getCurrentPosition returns the platform fix unchanged (modulo sub-meter jitter)', async () => {
  // The platform fix is 35.6762, 139.6503 with 12 m accuracy. Fine
  // granularity must not snap to a grid; only the ~2 m jitter in
  // makeCoordsFrom is allowed to perturb the values.
  const dom = loadLiveShim('location_spoof/live_fine.js', {
    lat: 35.6762, lng: 139.6503, acc: 12,
  });
  const pos = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  assert.ok(Math.abs(pos.coords.latitude - 35.6762) < 0.0001);
  assert.ok(Math.abs(pos.coords.longitude - 139.6503) < 0.0001);
  // Fine reports the platform-provided accuracy (no inflation).
  assert.equal(pos.coords.accuracy, 12);
});

test('live_coarse: getCurrentPosition snaps lat/lng to a ~1.1km grid', async () => {
  // Latitude rounds to the nearest 0.01° (~1.1 km). Longitude step is
  // divided by cos(snappedLat) so cells stay roughly square. Sub-meter
  // jitter is applied on top of the snapped value, so the reported
  // coords differ from the grid cell origin by less than 2 m.
  const dom = loadLiveShim('location_spoof/live_coarse.js', {
    lat: 35.6762, lng: 139.6503, acc: 12,
  });
  const pos = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  // Mirror the shim's coarsening: snap latitude first, then derive the
  // longitude step from the snapped latitude (not the raw one — see the
  // shim comment for why).
  const latStep = 0.01;
  const expectedLat = Math.round(35.6762 / latStep) * latStep;
  const cosSnappedLat = Math.cos(expectedLat * Math.PI / 180);
  const lngStep = latStep / cosSnappedLat;
  const expectedLng = Math.round(139.6503 / lngStep) * lngStep;
  assert.ok(Math.abs(pos.coords.latitude - expectedLat) < 0.0001,
    `lat ${pos.coords.latitude} not within jitter of grid cell ${expectedLat}`);
  assert.ok(Math.abs(pos.coords.longitude - expectedLng) < 0.0001,
    `lng ${pos.coords.longitude} not within jitter of grid cell ${expectedLng}`);
});

test('live_coarse: reported accuracy is inflated to at least 1100 m', async () => {
  // Platform-reported 12 m accuracy must not flow through unchanged —
  // coarse mode must report an accuracy that matches the grid extent so
  // pages know the fix is approximate.
  const dom = loadLiveShim('location_spoof/live_coarse.js', {
    lat: 35.6762, lng: 139.6503, acc: 12,
  });
  const pos = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  assert.ok(pos.coords.accuracy >= 1100,
    `accuracy ${pos.coords.accuracy} should be >=1100m in coarse mode`);
});

test('live_coarse: a fix already coarser than the floor keeps its accuracy', async () => {
  // If the platform already reports 5000 m (low-accuracy NETWORK
  // provider), coarse mode must not silently lower the reported accuracy
  // to 1100. Use max(real, floor) not just floor.
  const dom = loadLiveShim('location_spoof/live_coarse.js', {
    lat: 35.6762, lng: 139.6503, acc: 5000,
  });
  const pos = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  assert.equal(pos.coords.accuracy, 5000);
});

test('live_coarse: nearby fixes inside the same grid cell snap to the same coords', async () => {
  // The whole point of coarse mode is that small movements don't leak.
  // Two fixes 100 m apart inside the same ~1.1 km cell must produce the
  // same snapped lat/lng (modulo the 2 m jitter, which is well below
  // grid-cell resolution).
  const fix1 = { lat: 35.6760, lng: 139.6500, acc: 12 };
  const fix2 = { lat: 35.6765, lng: 139.6505, acc: 12 };
  let nextFix = fix1;
  const { loadShim: load } = require('./helpers/load_shim');
  const dom = load('location_spoof/live_coarse.js');
  dom.window.flutter_inappwebview = {
    callHandler(name) {
      if (name !== 'getRealLocation') return Promise.resolve(null);
      const f = nextFix;
      return Promise.resolve({
        status: 'ok', latitude: f.lat, longitude: f.lng, accuracy: f.acc,
      });
    },
  };
  const pos1 = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  nextFix = fix2;
  const pos2 = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  // Both fixes round into the same cell, so the snapped components are
  // identical. ~2 m jitter is well below 0.0001°, so a tight tolerance
  // catches a regression where the grid step changed.
  assert.ok(Math.abs(pos1.coords.latitude - pos2.coords.latitude) < 0.0001);
  assert.ok(Math.abs(pos1.coords.longitude - pos2.coords.longitude) < 0.0001);
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
