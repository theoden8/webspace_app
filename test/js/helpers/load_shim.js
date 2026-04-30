// Shared helpers for jsdom-based shim tests.
//
// The shims in lib/services/*.dart are normally injected at DOCUMENT_START
// into a real WebView. Here we re-create that environment by:
//   1. Loading the dumped fixture from test/js_fixtures/ (kept in sync via
//      tool/dump_shim_js.dart + the Dart drift-check test).
//   2. Spinning up jsdom with a configurable URL + initial HTML.
//   3. Running the shim source via window.eval, which runs *inside* the
//      jsdom realm so window/document/navigator overrides take effect.
//
// jsdom is not a real browser. APIs missing from jsdom (canvas fingerprint,
// WebGL, audio context, real CSS layout) cannot be exercised here — assert
// on shim *shape* (constructors replaced, getters defined, properties set)
// rather than on real-engine behaviour. For end-to-end privacy proofing run
// the same fixture through Playwright + CreepJS in a follow-up tier.

const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const repoRoot = path.resolve(__dirname, '..', '..', '..');
const fixturesRoot = path.join(repoRoot, 'test', 'js_fixtures');

function readFixture(relPath) {
  const abs = path.join(fixturesRoot, relPath);
  return fs.readFileSync(abs, 'utf8');
}

function makeDom({ url = 'https://example.com/', html, userAgent } = {}) {
  const initialHtml =
    html ?? '<!doctype html><html><head></head><body></body></html>';
  const opts = { url, pretendToBeVisual: true, runScripts: 'outside-only' };
  if (userAgent) opts.userAgent = userAgent;
  const dom = new JSDOM(initialHtml, opts);
  installBrowserPolyfills(dom.window);
  return dom;
}

// jsdom intentionally omits some browser APIs the shims wrap. Provide
// minimal stubs so the shim's `if (origFn)` guards see a real function
// and install their wrapper. Real-engine semantics aren't simulated —
// these stubs return inert defaults; the test asserts the shim's
// override layer, not the underlying behaviour.
function installBrowserPolyfills(window) {
  if (typeof window.matchMedia !== 'function') {
    window.matchMedia = function matchMedia(query) {
      return {
        matches: false,
        media: query,
        onchange: null,
        addListener() {},
        removeListener() {},
        addEventListener() {},
        removeEventListener() {},
        dispatchEvent() { return false; },
      };
    };
  }

  // jsdom omits the Geolocation API. The location-spoof shim patches
  // `navigator.geolocation` in-place AND `Geolocation.prototype.*` for
  // detection hardening — both must exist for the shim to install.
  if (!window.navigator.geolocation) {
    class Geolocation {
      getCurrentPosition() {}
      watchPosition() { return 0; }
      clearWatch() {}
    }
    window.Geolocation = Geolocation;
    Object.defineProperty(window.navigator, 'geolocation', {
      value: new Geolocation(),
      configurable: true,
    });
    class GeolocationCoordinates {}
    class GeolocationPosition {}
    window.GeolocationCoordinates = GeolocationCoordinates;
    window.GeolocationPosition = GeolocationPosition;
  }

  // jsdom omits WebRTC. The shim's "off" branch replaces the constructor
  // with a thrower; the "relay" branch wraps the real constructor. We
  // need at least a stand-in class so the wrap branch has something to
  // capture.
  if (typeof window.RTCPeerConnection !== 'function') {
    class RTCPeerConnection {
      constructor(config) {
        this.__config = config || {};
      }
      setLocalDescription(desc) {
        this.__lastSdp = desc;
        return Promise.resolve();
      }
      close() {}
    }
    window.RTCPeerConnection = RTCPeerConnection;
  }
}

// Run the shim source inside the jsdom realm. window.eval is what makes
// `this`, `window`, `navigator`, etc. resolve to the jsdom globals (vs the
// host Node globals).
function runInDom(dom, source) {
  dom.window.eval(source);
}

// Convenience: build a dom + run a fixture in one call.
function loadShim(fixtureRelPath, domOptions) {
  const dom = makeDom(domOptions);
  runInDom(dom, readFixture(fixtureRelPath));
  return dom;
}

module.exports = { readFixture, makeDom, runInDom, loadShim };
