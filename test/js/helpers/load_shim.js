// Shared helpers for jsdom-based shim tests.
//
// The scripts in lib/js/ are normally injected at DOCUMENT_START into a real
// WebView. Here we re-create that environment by:
//   1. Reading the script the way the app does (page_js.js: includes
//      resolved, CONFIG bound).
//   2. Spinning up jsdom with a configurable URL + initial HTML.
//   3. Running the source via window.eval, which runs *inside* the
//      jsdom realm so window/document/navigator overrides take effect.
//
// jsdom is not a real browser. APIs missing from jsdom (canvas fingerprint,
// WebGL, audio context, real CSS layout) cannot be exercised here — assert
// on shim *shape* (constructors replaced, getters defined, properties set)
// rather than on real-engine behaviour. End-to-end privacy proofing runs
// the same scripts through Puppeteer + FingerprintJS in
// test/browser/fingerprint_real_engine.test.js.

const { JSDOM } = require('jsdom');
const { pageJs } = require('./page_js');

function makeDom({ url = 'https://example.com/', html, userAgent, virtualConsole } = {}) {
  const initialHtml =
    html ?? '<!doctype html><html><head></head><body></body></html>';
  const opts = { url, pretendToBeVisual: true, runScripts: 'outside-only' };
  if (userAgent) opts.userAgent = userAgent;
  if (virtualConsole) opts.virtualConsole = virtualConsole;
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

  // jsdom omits the Permissions API. The location shim patches
  // Permissions.prototype.query so a page that asks for the geolocation
  // permission state sees what a real browser would show for the site's
  // grant; without a stand-in that branch never installs and goes untested.
  if (typeof window.Permissions !== 'function') {
    class Permissions {
      query(descriptor) {
        return Promise.resolve({
          state: 'prompt',
          status: 'prompt',
          name: descriptor && descriptor.name,
          onchange: null,
          addEventListener() {},
          removeEventListener() {},
          dispatchEvent() { return true; },
        });
      }
    }
    window.Permissions = Permissions;
    Object.defineProperty(window.navigator, 'permissions', {
      value: new Permissions(),
      configurable: true,
    });
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
      setConfiguration(config) {
        this.__config = config || {};
      }
      getConfiguration() {
        return this.__config;
      }
      close() {}
    }
    window.RTCPeerConnection = RTCPeerConnection;
  }

  // jsdom omits URL.createObjectURL / revokeObjectURL. The blob-url-capture
  // shim wraps both — without these stubs it early-returns and the wrapping
  // logic stays untested. The URL form is deterministic so a blob_download.js
  // config naming test-blob-1 can call into a captured blob without
  // hard-coding a random jsdom-generated URL.
  if (typeof window.URL.createObjectURL !== 'function') {
    let counter = 0;
    window.URL.createObjectURL = function createObjectURL(_obj) {
      counter += 1;
      return 'blob:https://example.test/test-blob-' + counter;
    };
    window.URL.revokeObjectURL = function revokeObjectURL(_url) {};
  }
}

// Run the shim source inside the jsdom realm. window.eval is what makes
// `this`, `window`, `navigator`, etc. resolve to the jsdom globals (vs the
// host Node globals).
function runInDom(dom, source) {
  dom.window.eval(source);
}

// Convenience: build a dom + run a fixture in one call.
// A fresh jsdom with [source] run in it.
function loadShim(source, domOptions) {
  const dom = makeDom(domOptions);
  runInDom(dom, source);
  return dom;
}

module.exports = { pageJs, makeDom, runInDom, loadShim };
