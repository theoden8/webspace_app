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
const { loadShim, makeDom, runInDom, readFixture } = require('./helpers/load_shim');

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

test('live_gps: getCurrentPosition returns the platform fix unchanged (modulo sub-meter jitter)', async () => {
  // The platform fix is 35.6762, 139.6503 with 12 m accuracy. GPS
  // granularity must not snap to a grid; only the ~2 m jitter in
  // makeCoordsFrom is allowed to perturb the values.
  const dom = loadLiveShim('location_spoof/live_gps.js', {
    lat: 35.6762, lng: 139.6503, acc: 12,
  });
  const pos = await new Promise((resolve, reject) => {
    dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
  });
  assert.ok(Math.abs(pos.coords.latitude - 35.6762) < 0.0001);
  assert.ok(Math.abs(pos.coords.longitude - 139.6503) < 0.0001);
  // GPS reports the platform-provided accuracy (no inflation).
  assert.equal(pos.coords.accuracy, 12);
});

// Parameterise the snap-tier scenarios so the GSM and Approximate tiers
// share the same correctness contract, only the grid step / accuracy
// floor differ. A regression on either tier fails its own row without
// false-positives on the other.
const SNAP_TIERS = [
  { name: 'approximate', fixture: 'location_spoof/live_approximate.js',
    latStep: 0.001, accFloor: 110 },
  { name: 'gsm',         fixture: 'location_spoof/live_gsm.js',
    latStep: 0.01,  accFloor: 1100 },
];

for (const tier of SNAP_TIERS) {
  test(`live_${tier.name}: getCurrentPosition snaps lat/lng to the tier grid`, async () => {
    // Latitude rounds to the nearest tier.latStep. Longitude step is
    // divided by cos(snappedLat) so cells stay roughly square. Sub-meter
    // jitter is applied on top of the snapped value, so the reported
    // coords differ from the grid cell origin by less than 2 m.
    const dom = loadLiveShim(tier.fixture, {
      lat: 35.6762, lng: 139.6503, acc: 12,
    });
    const pos = await new Promise((resolve, reject) => {
      dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
    });
    // Mirror the shim: snap latitude first, then derive the longitude
    // step from the snapped latitude (not the raw one — see shim comment).
    const expectedLat = Math.round(35.6762 / tier.latStep) * tier.latStep;
    const cosSnappedLat = Math.cos(expectedLat * Math.PI / 180);
    const lngStep = tier.latStep / cosSnappedLat;
    const expectedLng = Math.round(139.6503 / lngStep) * lngStep;
    assert.ok(Math.abs(pos.coords.latitude - expectedLat) < 0.0001,
      `lat ${pos.coords.latitude} not within jitter of grid cell ${expectedLat}`);
    assert.ok(Math.abs(pos.coords.longitude - expectedLng) < 0.0001,
      `lng ${pos.coords.longitude} not within jitter of grid cell ${expectedLng}`);
  });

  test(`live_${tier.name}: reported accuracy is inflated to at least the tier floor`, async () => {
    // A precise 12 m platform fix must not flow through unchanged —
    // snap tiers report an accuracy that matches the grid extent so
    // pages know the fix is approximate.
    const dom = loadLiveShim(tier.fixture, {
      lat: 35.6762, lng: 139.6503, acc: 12,
    });
    const pos = await new Promise((resolve, reject) => {
      dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
    });
    assert.ok(pos.coords.accuracy >= tier.accFloor,
      `accuracy ${pos.coords.accuracy} should be >=${tier.accFloor}m in ${tier.name} mode`);
  });

  test(`live_${tier.name}: a fix already coarser than the floor keeps its accuracy`, async () => {
    // If the platform already reports 5000 m (low-accuracy NETWORK
    // provider), snap mode must not silently lower the reported accuracy.
    // Use max(real, floor) not just floor.
    const dom = loadLiveShim(tier.fixture, {
      lat: 35.6762, lng: 139.6503, acc: 5000,
    });
    const pos = await new Promise((resolve, reject) => {
      dom.window.navigator.geolocation.getCurrentPosition(resolve, reject);
    });
    assert.equal(pos.coords.accuracy, 5000);
  });

  test(`live_${tier.name}: nearby fixes inside the same grid cell snap to the same coords`, async () => {
    // The whole point of snapping is that small movements don't leak.
    // Two fixes inside the same cell must produce the same snapped
    // lat/lng (modulo the 2 m jitter, which is well below the
    // grid-cell resolution for both tiers).
    const cell = tier.latStep / 4;   // safely inside one cell
    const fix1 = { lat: 35.6760, lng: 139.6500, acc: 12 };
    const fix2 = { lat: 35.6760 + cell, lng: 139.6500 + cell, acc: 12 };
    let nextFix = fix1;
    const { loadShim: load } = require('./helpers/load_shim');
    const dom = load(tier.fixture);
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
    // identical. ~2 m jitter is well below tier.latStep, so a tight
    // tolerance catches a regression where the grid step changed.
    assert.ok(Math.abs(pos1.coords.latitude - pos2.coords.latitude) < 0.0001);
    assert.ok(Math.abs(pos1.coords.longitude - pos2.coords.longitude) < 0.0001);
  });
}

test('toLocale* report the spoofed zone, not the system one', () => {
  // ECMA-402 has Date.prototype.toLocale{String,DateString,TimeString} call
  // the abstract formatting operation directly, so patching the global
  // `Intl.DateTimeFormat` never reached them. The host realm here is
  // unshimmed, which makes it the reference for what each zone should render.
  const at = (fixture, expr) =>
    loadShim(fixture).window.eval(expr);

  for (const [fixture, zone] of [
    ['location_spoof/timezone_only_utc.js', 'UTC'],
    ['location_spoof/timezone_only_tokyo.js', 'Asia/Tokyo'],
  ]) {
    for (const method of
        ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString']) {
      assert.equal(
        at(fixture, `new Date(0).${method}('en-US')`),
        new Date(0)[method]('en-US', { timeZone: zone }),
        `${method} under ${zone}`,
      );
    }
  }

  // Non-vacuous: two spoofed zones must disagree, which can only happen if
  // the shim is driving the zone rather than the host's.
  assert.notEqual(
    at('location_spoof/timezone_only_utc.js', "new Date(0).toLocaleString('en-US')"),
    at('location_spoof/timezone_only_tokyo.js', "new Date(0).toLocaleString('en-US')"),
  );
});

test('an explicit timeZone argument is still honoured', () => {
  const dom = loadShim('location_spoof/timezone_only_tokyo.js');
  assert.equal(
    dom.window.eval(
      "new Date(0).toLocaleString('en-US', { timeZone: 'America/New_York' })"),
    new Date(0).toLocaleString('en-US', { timeZone: 'America/New_York' }),
  );
});

test('the toLocale* wrappers keep a native arity', () => {
  // A native `Date.prototype.toLocaleString.length` is 0. Declaring
  // (locales, options) on the wrapper would make it 2, which is a
  // one-expression tell.
  const dom = loadShim('location_spoof/timezone_only_tokyo.js');
  for (const method of
      ['toLocaleString', 'toLocaleDateString', 'toLocaleTimeString']) {
    assert.equal(dom.window.eval(`Date.prototype.${method}.length`), 0);
    assert.match(
      dom.window.eval(`Function.prototype.toString.call(Date.prototype.${method})`),
      /\[native code\]/,
    );
  }
});

test('the language and timezone wrappers chain in either install order', () => {
  // Both wrap the same three methods and each only fills in an argument the
  // caller omitted, so locale and zone must both survive whichever installs
  // first.
  const LANG = readFixture('language/ja.js');
  const TZ = readFixture('location_spoof/timezone_only_tokyo.js');
  const expected = new Date(0).toLocaleString('ja', { timeZone: 'Asia/Tokyo' });

  for (const order of [[LANG, TZ], [TZ, LANG]]) {
    const dom = makeDom();
    for (const src of order) runInDom(dom, src);
    assert.equal(dom.window.eval('new Date(0).toLocaleString()'), expected);
  }
});

test('a zero-offset zone reports +0, never negative zero', () => {
  // `-Math.round(0)` is -0, and `Object.is(d.getTimezoneOffset(), -0)` is true
  // only under this shim: a real engine returns +0 for UTC. The instant
  // matters — the leak only appeared when the sub-second remainder was exactly
  // zero, which the quantized clock makes common — so probe both boundary and
  // non-boundary instants.
  const dom = loadShim('location_spoof/timezone_only_utc.js');
  const r = dom.window.eval(`(() => {
    const out = [];
    for (const ms of [0, 1, 500, 999, 1000, 1700000000000, 1700000000123]) {
      out.push(Object.is(new Date(ms).getTimezoneOffset(), -0));
    }
    return out;
  })()`);
  assert.deepEqual(Array.from(r), [false, false, false, false, false, false, false],
    'no instant may produce a negative-zero offset');
  assert.equal(dom.window.eval("new Date(0).getTimezoneOffset()"), 0);
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

// --- Blocked mode (LOC-OFF-001/002) ----------------------------------------
//
// `off` is the default for every new site, so these cover the common case.
// Before the fix `off` emitted no shim at all and the platform's own
// geolocation answered: on iOS/macOS/Linux a page could still reach the real
// device fix through the webview's permission prompt. (Android already denied
// by default — the plugin's WebChromeClient calls back with allow=false when
// no Dart handler is registered — so the bug was platform-dependent, which is
// worse than uniformly wrong.)

const BLOCKING_FIXTURES = [
  ['blocked', 'location_spoof/blocked.js'],
  ['spoof_without_coords', 'location_spoof/spoof_without_coords.js'],
];

// Resolve to what the page actually observed, so a shim that never calls
// either callback fails the assertion instead of hanging the test: leaving a
// request unanswered is its own bug, not a pass.
function observeGetCurrentPosition(dom, timeoutMs = 2000) {
  return new Promise((resolve) => {
    const timer = setTimeout(
      () => resolve({ outcome: 'no callback within ' + timeoutMs + 'ms' }),
      timeoutMs,
    );
    dom.window.navigator.geolocation.getCurrentPosition(
      (position) => { clearTimeout(timer); resolve({ outcome: 'success', position }); },
      (error) => { clearTimeout(timer); resolve({ outcome: 'error', error }); },
    );
  });
}

for (const [name, fixture] of BLOCKING_FIXTURES) {
  test(`${name}: getCurrentPosition invokes the error callback, never success`, async () => {
    const dom = loadShim(fixture);
    const seen = await observeGetCurrentPosition(dom);
    assert.equal(seen.outcome, 'error');
    assert.equal(seen.error.code, 1);
    assert.equal(seen.error.code, seen.error.PERMISSION_DENIED);
  });

  test(`${name}: the error is indistinguishable from a denied browser prompt`, async () => {
    // Detection hardening: a site that can tell "WebSpace refused" apart from
    // "the user tapped Block" learns the app is mediating.
    const dom = loadShim(fixture);
    const seen = await observeGetCurrentPosition(dom);
    assert.equal(seen.outcome, 'error');
    const err = seen.error;
    assert.deepEqual(Object.keys(err).sort(), [
      'PERMISSION_DENIED', 'POSITION_UNAVAILABLE', 'TIMEOUT', 'code', 'message',
    ].sort());
    assert.equal(err.POSITION_UNAVAILABLE, 2);
    assert.equal(err.TIMEOUT, 3);
    assert.match(err.message, /denied/i);
  });

  test(`${name}: navigator.geolocation still exists`, () => {
    // Deleting the API would be trivially detectable and is not what a denied
    // browser looks like.
    const dom = loadShim(fixture);
    const geo = dom.window.navigator.geolocation;
    assert.ok(geo);
    assert.equal(typeof geo.getCurrentPosition, 'function');
    assert.equal(typeof geo.watchPosition, 'function');
    assert.equal(typeof geo.clearWatch, 'function');
  });

  test(`${name}: watchPosition returns an id, errors once, and never polls`, async () => {
    const dom = loadShim(fixture);
    let errors = 0;
    let successes = 0;
    const id = dom.window.navigator.geolocation.watchPosition(
      () => { successes += 1; },
      () => { errors += 1; },
    );
    assert.equal(typeof id, 'number');
    // Longer than the shim's 150-400ms simulated latency and its 1s/5s poll
    // intervals, so a stray interval would show up as a second error.
    await new Promise((r) => setTimeout(r, 1400));
    assert.equal(successes, 0);
    assert.equal(errors, 1, 'exactly one refusal, and no silent no-op');
    dom.window.navigator.geolocation.clearWatch(id);
  });

  test(`${name}: the prototype methods are patched, not just the instance`, () => {
    // A site can reach past navigator.geolocation via Geolocation.prototype.
    const dom = loadShim(fixture);
    assert.equal(
      dom.window.Geolocation.prototype.getCurrentPosition,
      dom.window.navigator.geolocation.getCurrentPosition,
    );
  });

  test(`${name}: permissions.query reports 'denied'`, async () => {
    // Reporting 'granted' here and then failing every call is a combination
    // no real browser produces.
    const dom = loadShim(fixture);
    const status = await dom.window.navigator.permissions.query({ name: 'geolocation' });
    assert.equal(status.state, 'denied');
  });

  test(`${name}: patched geolocation methods still stringify as native`, () => {
    const dom = loadShim(fixture);
    const src = dom.window.navigator.geolocation.getCurrentPosition.toString();
    assert.equal(src, 'function getCurrentPosition() { [native code] }');
  });
}

test('a grant is unaffected: static_tokyo still reports permissions granted', async () => {
  const dom = loadShim('location_spoof/static_tokyo.js');
  const status = await dom.window.navigator.permissions.query({ name: 'geolocation' });
  assert.equal(status.state, 'granted');
});

test('permissions.query passes non-geolocation descriptors through untouched', async () => {
  const dom = loadShim('location_spoof/blocked.js');
  const status = await dom.window.navigator.permissions.query({ name: 'camera' });
  assert.equal(status.state, 'prompt');
});
