(function(){
  'use strict';
  // Re-entrance guard: WebKit and Android WebView both re-run
  // initialUserScripts on every frame load. Without this, the matchMedia
  // wrapper would wrap the previously-wrapped function and recurse.
  // The flag is per-window, so iframes still get the shim.
  if (window.__ws_desktop_shim__) return;
  window.__ws_desktop_shim__ = true;

  function def(obj, name, getter) {
    try {
      Object.defineProperty(obj, name, { get: getter, configurable: true });
    } catch (e) {}
  }

  // --- navigator.userAgentData → undefined ---
  // Our spoofed UA is Firefox-shaped, and Firefox does not implement the
  // User-Agent Client Hints API. Sites that feature-detect Client Hints
  // by reading `navigator.userAgentData` should see `undefined`, not the
  // Chromium-WebView-populated mobile object.
  def(navigator, 'userAgentData', function() { return undefined; });

  // --- Touch / platform signals ---
  def(navigator, 'maxTouchPoints', function() { return 0; });
  def(navigator, 'platform', function() { return "Linux x86_64"; });

  // Remove `'ontouchstart' in window` — redefine as undefined so property
  // lookup doesn't fall through to the real native handler.
  try {
    Object.defineProperty(window, 'ontouchstart', {
      value: undefined, configurable: true, writable: true
    });
  } catch (e) {}

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
      window.matchMedia = function(query) {
        if (typeof query === 'string') {
          if (FORCE_TRUE.test(query)) return synthetic(query, true);
          if (FORCE_FALSE.test(query)) return synthetic(query, false);
        }
        return origMM(query);
      };
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
