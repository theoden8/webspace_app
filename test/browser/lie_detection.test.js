// Tier 3 lie-detection probes — the same techniques CreepJS uses to
// flag a spoofed surface, applied to our shims.
//
// fingerprintjs (in fingerprint_real_engine.test.js) reads spoofed
// values; this file probes whether a fingerprinter could *tell that
// the surface was spoofed* by looking past the value:
//
//   - Function.prototype.toString.call(fn) — does the override
//     stringify as JS source or as native code?
//   - Object.getOwnPropertyNames(navigator) — does the override show
//     up as an own property where a real navigator only has
//     prototype-defined ones?
//   - Iframe escape — does a fresh `iframe.contentWindow.navigator`
//     reveal the un-overridden value (proves the shim only reaches
//     the main frame)?
//   - Getter source inspection via property descriptor — same
//     stringify trick at a different access path.
//
// Findings encoded as live assertions where the shim already
// withstands the probe; encoded as `t.todo` where a real-world
// fingerprinter would still detect the spoof, so a future hardening
// pass can flip the marker to a passing test without rewriting it.

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const {
  setupBrowser, requireBrowser, readFixture,
} = require('./helpers/launch');

const LINUX = readFixture('desktop_mode/linux.js');
const FULL_COMBO = readFixture('location_spoof/full_combo.js');
const THEME_DARK = readFixture('theme_color_scheme/dark.js');
const BLOB_SHIM = readFixture('blob_url_capture/shim.js');
const CAMERA_SHIM = readFixture('camera_stream/shim.js');

const browser = setupBrowser();

async function withShim(t, shim, fn) {
  if (!requireBrowser(browser, t)) return;
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(shim);
    await page.goto('about:blank', { waitUntil: 'load' });
    await fn(page);
  } finally {
    await page.close();
  }
}

// ---------- Function.prototype.toString native-code probe ----------

test('location_spoof: every override stringifies as native code',
  async (t) => {
    // The shim's WeakMap-keyed Function.prototype.toString patch
    // claims to make every spoofed function look native. Walk the
    // surfaces a fingerprinter would inspect and assert they all
    // pass the [native code] check.
    await withShim(t, FULL_COMBO, async (page) => {
      const r = await page.evaluate(() => {
        const probe = (fn) => Function.prototype.toString.call(fn);
        return {
          getCurrentPosition: probe(navigator.geolocation.getCurrentPosition),
          watchPosition: probe(navigator.geolocation.watchPosition),
          clearWatch: probe(navigator.geolocation.clearWatch),
          permissionsQuery: probe(navigator.permissions.query),
          getTimezoneOffset: probe(Date.prototype.getTimezoneOffset),
          dateToString: probe(Date.prototype.toString),
          IntlDateTimeFormat: probe(Intl.DateTimeFormat),
          // Sanity: a built-in we did NOT override should still
          // stringify as native — proves the patch isn't blanket.
          arrayPush: probe(Array.prototype.push),
        };
      });
      const NATIVE = /\[native code\]/;
      for (const [k, src] of Object.entries(r)) {
        assert.match(src, NATIVE,
          `${k} must stringify as native, got: ${src}`);
      }
    });
  });

test('desktop_mode: navigator.platform getter stringifies as native code',
  async (t) => {
    // Shim's WeakMap-keyed Function.prototype.toString stub (shared
    // with location_spoof via window.__wsFnStubs) makes the spoofed
    // getter look native. Probe via the prototype descriptor — the
    // shim now patches Navigator.prototype, not the navigator instance.
    await withShim(t, LINUX, async (page) => {
      const src = await page.evaluate(() => {
        const desc = Object.getOwnPropertyDescriptor(
          Navigator.prototype, 'platform');
        return Function.prototype.toString.call(desc.get);
      });
      assert.match(src, /\[native code\]/,
        `getter source leaks: ${src}`);
    });
  });

// ---------- Own-property enumeration leak ----------

test('desktop_mode: Object.getOwnPropertyNames(navigator) does not list overrides',
  async (t) => {
    // Clean Chromium reports an empty array. The shim now patches
    // Navigator.prototype rather than the instance, so navigator
    // stays clean — none of platform / userAgentData / maxTouchPoints
    // leak as own-properties.
    await withShim(t, LINUX, async (page) => {
      const ownProps = await page.evaluate(() =>
        Object.getOwnPropertyNames(navigator));
      for (const k of ['platform', 'userAgentData', 'maxTouchPoints']) {
        assert.equal(ownProps.includes(k), false,
          `${k} leaks as own-property of navigator: ${JSON.stringify(ownProps)}`);
      }
    });
  });

// ---------- Iframe escape ----------

test('iframe contentWindow inherits the spoofed navigator.platform',
  async (t) => {
    // A site that mints an `<iframe>` and reads
    // `iframe.contentWindow.navigator.platform` would otherwise see
    // the un-overridden value and detect the spoof. Puppeteer's
    // evaluateOnNewDocument is registered for every frame (mirroring
    // forMainFrameOnly:false on iOS WKUserScript), so the same shim
    // runs in the iframe realm.
    await withShim(t, LINUX, async (page) => {
      const r = await page.evaluate(async () => {
        const f = document.createElement('iframe');
        document.body.appendChild(f);
        // Wait for the frame's about:blank to settle so the iframe's
        // own document has finished its DOCUMENT_START injection.
        await new Promise((r) => setTimeout(r, 50));
        return {
          platform: f.contentWindow.navigator.platform,
          maxTouchPoints: f.contentWindow.navigator.maxTouchPoints,
          userAgentData: f.contentWindow.navigator.userAgentData,
        };
      });
      assert.equal(r.platform, 'Linux x86_64');
      assert.equal(r.maxTouchPoints, 0);
      assert.equal(r.userAgentData, undefined);
    });
  });

test('iframe contentWindow inherits the spoofed timezone', async (t) => {
  await withShim(t, FULL_COMBO, async (page) => {
    const tz = await page.evaluate(async () => {
      const f = document.createElement('iframe');
      document.body.appendChild(f);
      await new Promise((r) => setTimeout(r, 50));
      return new f.contentWindow.Intl.DateTimeFormat()
        .resolvedOptions().timeZone;
    });
    assert.equal(tz, 'Europe/Paris');
  });
});

// ---------- Property descriptor inspection ----------

test('location_spoof: descriptor for Date.prototype.getTimezoneOffset hides override',
  async (t) => {
    // Object.getOwnPropertyDescriptor(...).value.toString() is a
    // common CreepJS-style probe. With the WeakMap-keyed
    // toString stub the shim installs, this must return native shape.
    await withShim(t, FULL_COMBO, async (page) => {
      const src = await page.evaluate(() => {
        const desc = Object.getOwnPropertyDescriptor(
          Date.prototype, 'getTimezoneOffset');
        return Function.prototype.toString.call(desc.value);
      });
      assert.match(src, /\[native code\]/,
        `getTimezoneOffset descriptor leaks source: ${src}`);
    });
  });

test('location_spoof: Geolocation.prototype overrides all stringify as native',
  async (t) => {
    // Sites can read methods off Geolocation.prototype directly.
    // The shim re-defines all three on the prototype; all three must
    // pass the native-code stringification check.
    await withShim(t, FULL_COMBO, async (page) => {
      const r = await page.evaluate(() => ({
        get: Function.prototype.toString.call(
          Geolocation.prototype.getCurrentPosition),
        watch: Function.prototype.toString.call(
          Geolocation.prototype.watchPosition),
        clear: Function.prototype.toString.call(
          Geolocation.prototype.clearWatch),
      }));
      assert.match(r.get, /\[native code\]/);
      assert.match(r.watch, /\[native code\]/);
      assert.match(r.clear, /\[native code\]/);
    });
  });

// ---------- toString chain integrity ----------

test('location_spoof: Function.prototype.toString.toString is also stubbed',
  async (t) => {
    // A fingerprinter that suspects toString has been patched will
    // probe `Function.prototype.toString.toString()` to read the
    // patched function's own source. The shim self-stubs the patched
    // toString so this recursive probe also returns native shape.
    await withShim(t, FULL_COMBO, async (page) => {
      const src = await page.evaluate(() =>
        Function.prototype.toString.call(Function.prototype.toString));
      assert.match(src, /\[native code\]/,
        `Function.prototype.toString itself leaks source: ${src}`);
    });
  });

// ---------- location_spoof permissions own-property probe ----------

test('location_spoof: Object.getOwnPropertyNames(navigator.permissions) is empty',
  async (t) => {
    // Clean Chromium has Object.getOwnPropertyNames(navigator.permissions)
    // === [] — `query` lives only on Permissions.prototype. The hardened
    // shim patches the prototype, so no own-property leaks on the
    // permissions instance.
    await withShim(t, FULL_COMBO, async (page) => {
      const own = await page.evaluate(() =>
        Object.getOwnPropertyNames(navigator.permissions));
      assert.deepEqual(own, [],
        `navigator.permissions own-properties: ${JSON.stringify(own)}`);
    });
  });

test('location_spoof: Permissions.prototype.query is the override (not the instance)',
  async (t) => {
    await withShim(t, FULL_COMBO, async (page) => {
      const r = await page.evaluate(() => {
        const protoDesc = Object.getOwnPropertyDescriptor(
          Permissions.prototype, 'query');
        return {
          src: Function.prototype.toString.call(protoDesc.value),
          // The instance must NOT have its own query — clean Chromium
          // resolves through the prototype.
          instanceHasOwn: Object.prototype.hasOwnProperty.call(
            navigator.permissions, 'query'),
        };
      });
      assert.match(r.src, /\[native code\]/);
      assert.equal(r.instanceHasOwn, false);
    });
  });

// ---------- theme_color_scheme matchMedia probe ----------

test('theme_color_scheme: window.matchMedia stringifies as native code',
  async (t) => {
    // Same hardening as desktop_mode + location_spoof — the WeakMap
    // toString stub ported into theme_color_scheme means
    // Function.prototype.toString.call(matchMedia) reads back as
    // native instead of leaking the wrapper source.
    if (!requireBrowser(browser, t)) return;
    const page = await browser.browser.newPage();
    try {
      await page.goto('about:blank', { waitUntil: 'load' });
      await page.evaluate(THEME_DARK);
      const src = await page.evaluate(() =>
        Function.prototype.toString.call(window.matchMedia));
      assert.match(src, /\[native code\]/,
        `matchMedia source leaks: ${src}`);
    } finally {
      await page.close();
    }
  });

// ---------- blob_url_capture URL.* probes ----------

test('blob_url_capture: URL.createObjectURL stringifies as native code',
  async (t) => {
    if (!requireBrowser(browser, t)) return;
    const page = await browser.browser.newPage();
    try {
      await page.evaluateOnNewDocument(BLOB_SHIM);
      await page.goto('about:blank', { waitUntil: 'load' });
      const r = await page.evaluate(() => ({
        create: Function.prototype.toString.call(URL.createObjectURL),
        revoke: Function.prototype.toString.call(URL.revokeObjectURL),
      }));
      assert.match(r.create, /\[native code\]/,
        `createObjectURL source leaks: ${r.create}`);
      assert.match(r.revoke, /\[native code\]/,
        `revokeObjectURL source leaks: ${r.revoke}`);
    } finally {
      await page.close();
    }
  });

test('blob_url_capture: capture still works after the toString hardening',
  async (t) => {
    // Sanity: hardening must not break the actual capture machinery —
    // a Blob minted via the wrapped createObjectURL must still appear
    // in window.__webspaceBlobs.
    if (!requireBrowser(browser, t)) return;
    const page = await browser.browser.newPage();
    try {
      await page.evaluateOnNewDocument(BLOB_SHIM);
      await page.goto('about:blank', { waitUntil: 'load' });
      const r = await page.evaluate(() => {
        const blob = new Blob(['hello'], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        const captured = window.__webspaceBlobs.get(url);
        return { hit: captured === blob };
      });
      assert.equal(r.hit, true,
        'wrapped createObjectURL must still register the Blob');
    } finally {
      await page.close();
    }
  });

// ---------- camera_stream lie-detection probes ----------
//
// The virtual camera substitutes a user-picked image/clip for the device
// camera. A page that can TELL the stream was substituted-by-this-browser
// can single WebSpace users out, so the shim has to look like an ordinary
// camera at the same surfaces the probes above cover for the other shims.
//
// getUserMedia only exists in a secure context, and about:blank is not one,
// so this section serves its page from 127.0.0.1 (a Chromium secure-origin
// exception) instead of reusing withShim().

function startSecureOriginServer() {
  return new Promise((resolve) => {
    const server = http.createServer((_req, res) => {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end('<!doctype html><html><head></head><body></body></html>');
    });
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

// Runs `fn(page)` with the camera shim installed and the bridge answering
// `virtual` with a 1x1 image, so a stream can actually be served.
async function withCameraShim(t, fn) {
  if (!requireBrowser(browser, t)) return;
  const server = await startSecureOriginServer();
  const page = await browser.browser.newPage();
  try {
    await page.evaluateOnNewDocument(() => {
      window.flutter_inappwebview = {
        callHandler: (name) => Promise.resolve(
          name === 'webCameraMode'
            ? 'virtual'
            : {
              mode: 'virtual',
              source: {
                kind: 'image',
                dataUrl: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEA'
                  + 'AAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJ'
                  + 'RU5ErkJggg==',
              },
            }),
      };
    });
    await page.evaluateOnNewDocument(CAMERA_SHIM);
    await page.goto(`http://127.0.0.1:${server.address().port}/`,
      { waitUntil: 'load' });
    await fn(page);
  } finally {
    await page.close();
    server.close();
  }
}

test('camera_stream: getUserMedia and enumerateDevices stringify as native',
  async (t) => {
    await withCameraShim(t, async (page) => {
      const r = await page.evaluate(() => {
        const s = (fn) => Function.prototype.toString.call(fn);
        return {
          gum: s(navigator.mediaDevices.getUserMedia),
          enumerate: s(navigator.mediaDevices.enumerateDevices),
        };
      });
      assert.match(r.gum, /\[native code\]/,
        `getUserMedia leaks its source: ${r.gum}`);
      assert.match(r.enumerate, /\[native code\]/,
        `enumerateDevices leaks its source: ${r.enumerate}`);
    });
  });

test('camera_stream: overrides sit on MediaDevices.prototype, not the instance',
  async (t) => {
    // Assigning to navigator.mediaDevices directly would leave the overrides
    // enumerable as own-properties, where a real browser has none.
    await withCameraShim(t, async (page) => {
      const r = await page.evaluate(() => ({
        own: Object.getOwnPropertyNames(navigator.mediaDevices),
        protoHasGum: Object.getOwnPropertyNames(MediaDevices.prototype)
          .includes('getUserMedia'),
      }));
      assert.deepEqual(r.own, [],
        `overrides leak as own-properties of mediaDevices: ${JSON.stringify(r.own)}`);
      assert.equal(r.protoHasGum, true);
    });
  });

test('camera_stream: the synthetic track passes for an ordinary camera track',
  async (t) => {
    await withCameraShim(t, async (page) => {
      const r = await page.evaluate(async () => {
        const stream = await navigator.mediaDevices.getUserMedia({ video: true });
        const track = stream.getVideoTracks()[0];
        const s = (fn) => Function.prototype.toString.call(fn);
        const labelDesc =
          Object.getOwnPropertyDescriptor(MediaStreamTrack.prototype, 'label');
        return {
          own: Object.getOwnPropertyNames(track),
          ctor: Object.getPrototypeOf(track).constructor.name,
          label: track.label,
          labelOnInstance: !!Object.getOwnPropertyDescriptor(track, 'label'),
          labelGetter: labelDesc && labelDesc.get ? s(labelDesc.get) : 'none',
          getSettings: s(track.getSettings),
          stop: s(track.stop),
          settings: track.getSettings(),
        };
      });
      assert.deepEqual(r.own, [],
        `track carries own-properties a real one lacks: ${JSON.stringify(r.own)}`);
      // A canvas-backed track is a CanvasCaptureMediaStreamTrack, which is a
      // direct tell; the shim re-points the prototype.
      assert.equal(r.ctor, 'MediaStreamTrack',
        `track class reveals the canvas origin: ${r.ctor}`);
      assert.equal(r.labelOnInstance, false);
      assert.match(r.labelGetter, /\[native code\]/,
        `the label getter leaks its source: ${r.labelGetter}`);
      assert.match(r.getSettings, /\[native code\]/);
      assert.match(r.stop, /\[native code\]/);
      assert.equal(r.label, 'Integrated Camera');
      assert.equal(r.settings.facingMode, 'environment');
      assert.equal(typeof r.settings.deviceId, 'string');
    });
  });

test('camera_stream: a real camera track keeps its own label', async (t) => {
  // The prototype-level overrides dispatch on a WeakMap of synthetic tracks;
  // a non-synthetic track must fall through to the platform getter, or every
  // page in the realm would report our label.
  await withCameraShim(t, async (page) => {
    const r = await page.evaluate(() => {
      const canvas = document.createElement('canvas');
      canvas.width = 8; canvas.height = 8;
      canvas.getContext('2d').fillRect(0, 0, 8, 8);
      // A canvas track the shim never served: not in the WeakMap.
      const foreign = canvas.captureStream(1).getVideoTracks()[0];
      return { label: foreign.label, settingsFacing: foreign.getSettings().facingMode };
    });
    assert.notEqual(r.label, 'Integrated Camera',
      'a track the shim did not create must keep its real label');
    assert.equal(r.settingsFacing, undefined,
      'a foreign track must not be given a fake facingMode');
  });
});

// Known gaps — shared by EVERY shim in this repo, not specific to the
// camera. Encoded as todo so a future hardening pass flips the marker
// instead of rewriting the assertion (same convention as above).

test('camera_stream: install markers are invisible on window', async (t) => {
  // Every shim announces itself with a `__ws*` global (idempotency guard +
  // the shared Function.prototype.toString WeakMap). The location shim
  // exposes __wsLocShimInstalled the same way, so fixing this means moving
  // the whole convention to Symbols, not patching one shim.
  t.todo('repo-wide: __ws* install markers enumerable via getOwnPropertyNames(window)');
});

test('camera_stream: cross-realm toString hides the override source',
  async (t) => {
    // `Function.prototype.toString.call(iframe.contentWindow.navigator
    // .mediaDevices.getUserMedia)` from the PARENT realm prints the shim
    // source: the stub WeakMap is per-realm, so the parent's patched
    // toString does not recognise the child's function. Verified identical
    // for location_spoof, so this is the shared funnel's gap.
    t.todo('repo-wide: parent-realm toString reveals a child realm override');
  });
