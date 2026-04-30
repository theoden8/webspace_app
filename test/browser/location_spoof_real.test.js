// Real-Chromium tests for the location-spoof shim
// (lib/services/location_spoof_service.dart, dumped to
// test/js_fixtures/location_spoof/*.js).
//
// jsdom does not implement Intl timezone arithmetic against arbitrary
// IANA zones (it falls back to the host's TZ for getTimezoneOffset),
// has no Geolocation API beyond what the polyfill stubs in, and has no
// real RTCPeerConnection. The test/js/location_spoof_shim.test.js
// file therefore can only assert the shim *installs* — that
// constructors are replaced and getters defined. These tests prove the
// installed surface actually answers correctly for a real engine:
//
//   - Intl.DateTimeFormat().resolvedOptions().timeZone reports the
//     spoofed zone.
//   - Date.prototype.getTimezoneOffset returns the DST-correct offset
//     for both winter and summer instants in Europe/Paris.
//   - Date.prototype.toString includes the spoofed zone abbreviation.
//   - navigator.geolocation.getCurrentPosition resolves with coords
//     within sub-meter jitter of the configured lat/lng.
//   - navigator.permissions.query({name:'geolocation'}) reports
//     granted (real Chromium would otherwise prompt).
//   - new RTCPeerConnection() throws when WRTC=off.
//   - When WRTC=relay, the wrapper forces config.iceTransportPolicy
//     to 'relay' and filters non-relay a=candidate: lines from any
//     SDP passed to setLocalDescription.

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const FULL_COMBO = readFixture('location_spoof/full_combo.js');
const STATIC_TOKYO = readFixture('location_spoof/static_tokyo.js');
const TZ_ONLY_TOKYO = readFixture('location_spoof/timezone_only_tokyo.js');
const WRTC_DISABLED = readFixture('location_spoof/webrtc_disabled.js');
const WRTC_RELAY = readFixture('location_spoof/webrtc_relay.js');

const browser = setupBrowser();

async function withShim(t, shim, fn, { preInit } = {}) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    if (preInit) await page.evaluateOnNewDocument(preInit);
    await page.evaluateOnNewDocument(shim);
    // about:blank is enough — none of the assertions need a network
    // realm. evaluateOnNewDocument fires for about:blank too.
    await page.goto('about:blank', { waitUntil: 'load' });
    await fn(page);
  } finally {
    await page.close();
  }
}

// ---------- Timezone ----------

test('Intl.DateTimeFormat().resolvedOptions().timeZone reports spoofed zone (Tokyo)',
  async (t) => {
    await withShim(t, TZ_ONLY_TOKYO, async (page) => {
      const tz = await page.evaluate(() =>
        new Intl.DateTimeFormat().resolvedOptions().timeZone);
      assert.equal(tz, 'Asia/Tokyo');
    });
  });

test('Intl.DateTimeFormat().resolvedOptions().timeZone reports spoofed zone (Paris)',
  async (t) => {
    await withShim(t, FULL_COMBO, async (page) => {
      const tz = await page.evaluate(() =>
        new Intl.DateTimeFormat().resolvedOptions().timeZone);
      assert.equal(tz, 'Europe/Paris');
    });
  });

test('Intl.DateTimeFormat with explicit timeZone is left alone', async (t) => {
  // The shim only injects timeZone when one is not already set;
  // sites that explicitly pass one must still get what they asked for.
  await withShim(t, FULL_COMBO, async (page) => {
    const tz = await page.evaluate(() =>
      new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York' })
        .resolvedOptions().timeZone);
    assert.equal(tz, 'America/New_York');
  });
});

test('Date.getTimezoneOffset returns DST-correct offset for Europe/Paris',
  async (t) => {
    // Paris is CET (UTC+1, offset -60) in January and CEST (UTC+2,
    // offset -120) in July. If the shim were doing a fixed offset,
    // both would return the same value — a real-engine test catches
    // that regression.
    await withShim(t, FULL_COMBO, async (page) => {
      const r = await page.evaluate(() => ({
        winter: new Date('2024-01-15T12:00:00Z').getTimezoneOffset(),
        summer: new Date('2024-07-15T12:00:00Z').getTimezoneOffset(),
      }));
      assert.equal(r.winter, -60, 'CET in January should be -60');
      assert.equal(r.summer, -120, 'CEST in July should be -120');
    });
  });

test('Date.getTimezoneOffset returns -540 for Asia/Tokyo year-round',
  async (t) => {
    await withShim(t, TZ_ONLY_TOKYO, async (page) => {
      const r = await page.evaluate(() => ({
        winter: new Date('2024-01-15T12:00:00Z').getTimezoneOffset(),
        summer: new Date('2024-07-15T12:00:00Z').getTimezoneOffset(),
      }));
      assert.equal(r.winter, -540);
      assert.equal(r.summer, -540, 'Tokyo has no DST');
    });
  });

test('Date.prototype.toString embeds the spoofed offset string', async (t) => {
  await withShim(t, FULL_COMBO, async (page) => {
    const s = await page.evaluate(() =>
      new Date('2024-07-15T12:00:00Z').toString());
    // Format: "Mon Jul 15 2024 14:00:00 GMT+0200 (Central European Summer Time)"
    assert.match(s, /GMT\+0200/);
    assert.match(s, /^[A-Z][a-z]{2} Jul 15 2024 14:00:00/);
  });
});

test('Function.prototype.toString hides the override on getTimezoneOffset',
  async (t) => {
    // Fingerprinters call `Function.prototype.toString.call(fn)` to
    // detect monkey-patches. The shim's WeakMap-keyed stub returns the
    // native form so this probe sees nothing unusual.
    await withShim(t, FULL_COMBO, async (page) => {
      const s = await page.evaluate(() =>
        Function.prototype.toString.call(Date.prototype.getTimezoneOffset));
      assert.equal(s, 'function getTimezoneOffset() { [native code] }');
    });
  });

// ---------- Geolocation ----------

test('getCurrentPosition resolves to spoofed coords (within jitter)',
  async (t) => {
    await withShim(t, STATIC_TOKYO, async (page) => {
      const pos = await page.evaluate(() =>
        new Promise((resolve, reject) => {
          navigator.geolocation.getCurrentPosition(
            (p) => resolve({
              lat: p.coords.latitude,
              lng: p.coords.longitude,
              acc: p.coords.accuracy,
              ts: p.timestamp,
            }),
            (e) => reject(new Error('error code ' + e.code)));
        }));
      // The shim adds ±0.00001 jitter; we built the fixture with
      // (35.6762, 139.6503, 25.0).
      assert.ok(Math.abs(pos.lat - 35.6762) < 0.0001, `lat ${pos.lat}`);
      assert.ok(Math.abs(pos.lng - 139.6503) < 0.0001, `lng ${pos.lng}`);
      assert.equal(pos.acc, 25.0);
      assert.equal(typeof pos.ts, 'number');
    });
  });

test('Geolocation.prototype.getCurrentPosition is also overridden',
  async (t) => {
    // Sites can read the prototype reference before navigator.geolocation
    // is touched. The shim must patch both surfaces.
    await withShim(t, STATIC_TOKYO, async (page) => {
      const pos = await page.evaluate(() =>
        new Promise((resolve) => {
          Geolocation.prototype.getCurrentPosition.call(
            navigator.geolocation,
            (p) => resolve({
              lat: p.coords.latitude,
              lng: p.coords.longitude,
            }));
        }));
      assert.ok(Math.abs(pos.lat - 35.6762) < 0.0001);
      assert.ok(Math.abs(pos.lng - 139.6503) < 0.0001);
    });
  });

test('watchPosition fires repeatedly with sub-meter jitter', async (t) => {
  // The static-mode watcher polls every 1s; we collect 3 frames and
  // assert they are not byte-identical (the shim adds jitter so
  // page.requestAnimationFrame-driven motion sensors don't see a
  // perfectly stationary device).
  await withShim(t, STATIC_TOKYO, async (page) => {
    const frames = await page.evaluate(() =>
      new Promise((resolve) => {
        const seen = [];
        const id = navigator.geolocation.watchPosition((p) => {
          seen.push({ lat: p.coords.latitude, lng: p.coords.longitude });
          if (seen.length >= 3) {
            navigator.geolocation.clearWatch(id);
            resolve(seen);
          }
        });
      }));
    assert.equal(frames.length, 3);
    // At least one pair of consecutive frames should differ — the
    // jitter is per-call so identical frames are vanishingly unlikely.
    const allSame = frames.every((f, i) => i === 0
      || (f.lat === frames[0].lat && f.lng === frames[0].lng));
    assert.equal(allSame, false, 'watchPosition frames should not be identical');
  });
});

test('permissions.query({name:"geolocation"}) reports granted', async (t) => {
  // Without the override, Chromium would resolve to 'prompt' (no user
  // grant in headless), and a site checking permissions before
  // calling getCurrentPosition would short-circuit and never see the
  // spoofed coords.
  await withShim(t, STATIC_TOKYO, async (page) => {
    const r = await page.evaluate(async () => {
      const s = await navigator.permissions.query({ name: 'geolocation' });
      return { state: s.state, status: s.status };
    });
    assert.equal(r.state, 'granted');
    assert.equal(r.status, 'granted');
  });
});

test('permissions.query for non-geolocation permissions falls through',
  async (t) => {
    // The shim must not hijack other permission queries — only the
    // geolocation slot is forged.
    await withShim(t, STATIC_TOKYO, async (page) => {
      const state = await page.evaluate(async () => {
        try {
          const s = await navigator.permissions.query({ name: 'notifications' });
          return s.state;
        } catch (e) {
          return 'threw:' + e.message;
        }
      });
      // In headless Chromium without a user gesture, notifications
      // resolves to 'prompt' or 'denied' — anything but 'granted'
      // proves we did not hijack it.
      assert.notEqual(state, 'granted',
        'non-geolocation permissions must not be forged to granted');
    });
  });

test('Function.prototype.toString hides the override on getCurrentPosition',
  async (t) => {
    await withShim(t, STATIC_TOKYO, async (page) => {
      const s = await page.evaluate(() =>
        Function.prototype.toString.call(navigator.geolocation.getCurrentPosition));
      assert.equal(s, 'function getCurrentPosition() { [native code] }');
    });
  });

// ---------- WebRTC ----------

test('WRTC=off — new RTCPeerConnection() throws', async (t) => {
  await withShim(t, WRTC_DISABLED, async (page) => {
    const r = await page.evaluate(() => {
      try {
        new RTCPeerConnection();
        return { threw: false };
      } catch (e) {
        return { threw: true, message: e.message };
      }
    });
    assert.equal(r.threw, true);
    assert.match(r.message, /WebRTC disabled/);
  });
});

test('WRTC=off — Function.prototype.toString hides the override', async (t) => {
  await withShim(t, WRTC_DISABLED, async (page) => {
    const s = await page.evaluate(() =>
      Function.prototype.toString.call(window.RTCPeerConnection));
    assert.equal(s, 'function RTCPeerConnection() { [native code] }');
  });
});

test('WRTC=relay — config.iceTransportPolicy is forced to relay',
  async (t) => {
    // Pre-install a fake RTCPeerConnection BEFORE the shim runs so we
    // can observe what the shim's wrapper passes through. The shim's
    // relay branch reads `_RealRTC = window.RTCPeerConnection` at
    // install time, then constructs an instance per call after
    // mutating the config in place.
    const FAKE = `
      window.__rtcEvents = [];
      class FakeRTC {
        constructor(config) {
          this.__config = config;
          window.__rtcEvents.push({
            type: 'ctor',
            config: JSON.parse(JSON.stringify(config || {})),
          });
        }
        setLocalDescription(desc) {
          window.__rtcEvents.push({
            type: 'setLocal',
            sdp: desc && desc.sdp,
          });
          return Promise.resolve();
        }
        close() {}
      }
      window.RTCPeerConnection = FakeRTC;
      window.webkitRTCPeerConnection = FakeRTC;
    `;
    await withShim(t, WRTC_RELAY, async (page) => {
      const events = await page.evaluate(() => {
        new RTCPeerConnection({
          iceServers: [{ urls: 'stun:example.test' }],
          iceTransportPolicy: 'all',
        });
        return window.__rtcEvents;
      });
      const ctor = events.find((e) => e.type === 'ctor');
      assert.ok(ctor, 'ctor event must fire on the underlying fake');
      assert.equal(ctor.config.iceTransportPolicy, 'relay',
        'shim must force iceTransportPolicy to relay');
      assert.deepEqual(ctor.config.iceServers,
        [{ urls: 'stun:example.test' }],
        'other config fields must be preserved');
    }, { preInit: FAKE });
  });

test('WRTC=relay — setLocalDescription strips non-relay candidates',
  async (t) => {
    const FAKE = `
      window.__rtcEvents = [];
      class FakeRTC {
        constructor(config) { this.__config = config; }
        setLocalDescription(desc) {
          window.__rtcEvents.push({ type: 'setLocal', sdp: desc.sdp });
          return Promise.resolve();
        }
        close() {}
      }
      window.RTCPeerConnection = FakeRTC;
    `;
    await withShim(t, WRTC_RELAY, async (page) => {
      const sdp = await page.evaluate(async () => {
        const pc = new RTCPeerConnection({});
        const offer = {
          type: 'offer',
          sdp: [
            'v=0',
            'o=- 1 1 IN IP4 0.0.0.0',
            's=-',
            'a=candidate:1 1 udp 1 192.0.2.1 1234 typ host',
            'a=candidate:2 1 udp 1 198.51.100.2 5678 typ relay',
            'a=candidate:3 1 udp 1 203.0.113.3 9012 typ srflx',
            'm=audio 9 UDP/TLS/RTP/SAVPF 0',
            '',
          ].join('\r\n'),
        };
        await pc.setLocalDescription(offer);
        return window.__rtcEvents.find((e) => e.type === 'setLocal').sdp;
      });
      assert.ok(!/typ host/.test(sdp),
        'host candidate (which leaks LAN IP) must be stripped');
      assert.ok(!/typ srflx/.test(sdp),
        'srflx candidate (which leaks public IP) must be stripped');
      assert.ok(/typ relay/.test(sdp),
        'relay candidate must be retained');
      // Non-candidate lines must survive unmolested.
      assert.ok(/^v=0/m.test(sdp));
      assert.ok(/^m=audio/m.test(sdp));
    }, { preInit: FAKE });
  });

test('WRTC=relay — Function.prototype.toString hides the wrapper',
  async (t) => {
    const FAKE = `
      class FakeRTC { constructor() {} close() {} }
      window.RTCPeerConnection = FakeRTC;
    `;
    await withShim(t, WRTC_RELAY, async (page) => {
      const s = await page.evaluate(() =>
        Function.prototype.toString.call(window.RTCPeerConnection));
      assert.equal(s, 'function RTCPeerConnection() { [native code] }');
    }, { preInit: FAKE });
  });
