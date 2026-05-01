(function(){
  'use strict';
  // Re-entrance guard: WebKit and Android WebView both re-run
  // initialUserScripts on every frame load. Without this, the matchMedia
  // wrapper would wrap the previously-wrapped function and recurse.
  // The flag is per-window, so iframes still get the shim.
  if (window.__ws_desktop_shim__) return;
  window.__ws_desktop_shim__ = true;

  // --- Function.prototype.toString hardening ---
  // Fingerprinters call `Function.prototype.toString.call(fn)` to detect
  // monkey-patched getters. The WeakMap-keyed stub makes every spoofed
  // function stringify as native. Shared with location_spoof_service.dart
  // via window.__wsFnStubs so both shims see one patched toString.
  var _origFnToString = Function.prototype.toString;
  var _stubs = window.__wsFnStubs || new WeakMap();
  window.__wsFnStubs = _stubs;
  function asNative(fn, name) {
    _stubs.set(fn, 'function ' + name + '() { [native code] }');
    return fn;
  }
  if (!window.__wsFnToStringPatched) {
    window.__wsFnToStringPatched = true;
    var patched = function toString() {
      var stub = _stubs.get(this);
      return stub !== undefined ? stub : _origFnToString.call(this);
    };
    _stubs.set(patched, 'function toString() { [native code] }');
    try { Function.prototype.toString = patched; } catch (e) {}
  }

  // Patch on Navigator.prototype, not the navigator instance. A clean
  // navigator carries these on the prototype; defining them on the
  // instance would leak via `Object.getOwnPropertyNames(navigator)`.
  function def(name, getter) {
    try {
      Object.defineProperty(Navigator.prototype, name, {
        get: getter, configurable: true, enumerable: true
      });
    } catch (e) {}
  }

  // --- navigator.userAgentData → undefined ---
  // Our spoofed UA is Firefox-shaped, and Firefox does not implement the
  // User-Agent Client Hints API. Sites that feature-detect Client Hints
  // by reading `navigator.userAgentData` should see `undefined`, not the
  // Chromium-WebView-populated mobile object. Only present on
  // Navigator.prototype in secure contexts (https / 127.0.0.1).
  def('userAgentData', asNative(function() { return undefined; }, 'userAgentData'));

  // --- Touch / platform signals ---
  def('maxTouchPoints', asNative(function() { return 0; }, 'maxTouchPoints'));
  def('platform', asNative(function() { return "Linux x86_64"; }, 'platform'));

  // Remove `'ontouchstart' in window`. Clean desktop Chromium does not
  // expose ontouchstart at all (it's only on Window.prototype on touch
  // builds), so defining it as undefined is the leak we used to ship —
  // `'ontouchstart' in window` would still return true for the
  // own-property. Delete from both window and Window.prototype.
  try { delete window.ontouchstart; } catch (e) {}
  try { delete Window.prototype.ontouchstart; } catch (e) {}

  // --- matchMedia wrapper for pointer/hover queries ---
  // Force `(pointer: fine)`, `(hover: hover)`, and the `any-*` variants
  // to match; force `coarse`/`none` opposites not to match. Other queries
  // (width-based, prefers-color-scheme, etc.) fall through to the real
  // implementation.
  try {
    var origMM = window.matchMedia && window.matchMedia.bind(window);
    if (origMM) {
      var FORCE_TRUE =
        /\((?:any-)?pointer:\s*fine\)|\((?:any-)?hover:\s*hover\)/i;
      var FORCE_FALSE =
        /\((?:any-)?pointer:\s*coarse\)|\((?:any-)?hover:\s*none\)/i;
      function synthetic(query, matches) {
        var listeners = [];
        return {
          matches: matches,
          media: query,
          onchange: null,
          addListener: function(l) { listeners.push(l); },
          removeListener: function(l) {
            var i = listeners.indexOf(l);
            if (i >= 0) listeners.splice(i, 1);
          },
          addEventListener: function(_t, l) { listeners.push(l); },
          removeEventListener: function(_t, l) {
            var i = listeners.indexOf(l);
            if (i >= 0) listeners.splice(i, 1);
          },
          dispatchEvent: function() { return false; }
        };
      }
      var _patchedMM = function matchMedia(query) {
        if (typeof query === 'string') {
          if (FORCE_TRUE.test(query)) return synthetic(query, true);
          if (FORCE_FALSE.test(query)) return synthetic(query, false);
        }
        return origMM(query);
      };
      asNative(_patchedMM, 'matchMedia');
      window.matchMedia = _patchedMM;
    }
  } catch (e) {}

  // --- <meta name="viewport"> rewrite ---
  // A site shipping `<meta name=viewport content="width=device-width">`
  // defeats `useWideViewPort`: CSS lays out at the phone's real CSS pixel
  // width, so responsive breakpoints pick the mobile layout. Rewrite any
  // viewport meta to a desktop-ish width=1280 as soon as it appears.
  var VIEWPORT_CONTENT = 'width=1280, initial-scale=1.0';
  function rewriteExistingViewports() {
    try {
      var metas = document.querySelectorAll('meta[name="viewport" i]');
      for (var i = 0; i < metas.length; i++) {
        metas[i].setAttribute('content', VIEWPORT_CONTENT);
      }
    } catch (e) {}
  }
  rewriteExistingViewports();
  try {
    var mo = new MutationObserver(function(mutations) {
      for (var i = 0; i < mutations.length; i++) {
        var added = mutations[i].addedNodes;
        if (!added) continue;
        for (var j = 0; j < added.length; j++) {
          var n = added[j];
          if (n && n.nodeType === 1 && n.tagName === 'META') {
            var nm = n.getAttribute && n.getAttribute('name');
            if (nm && nm.toLowerCase() === 'viewport') {
              n.setAttribute('content', VIEWPORT_CONTENT);
            }
          }
        }
      }
    });
    if (document.documentElement) {
      mo.observe(document.documentElement, { childList: true, subtree: true });
    }
  } catch (e) {}

  // Intentionally NOT spoofing `window.devicePixelRatio` or
  // `window.innerWidth` / `screen.width`. DPR is orthogonal to desktop-vs-
  // mobile layout — modern retina displays report dpr >= 2 — and width
  // properties are backed by native layout measurements; the meta-viewport
  // rewrite above handles width-based layout via the WebView's own
  // useWideViewPort path.
})();
