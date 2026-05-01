// Desktop-mode JavaScript shim.
//
// When a site's User-Agent looks like a desktop Firefox UA
// (`isDesktopUserAgent(ua) == true`), we inject this shim at
// AT_DOCUMENT_START to patch the JS-side signals the underlying mobile
// WebView still emits despite the spoofed UA.
//
// Why this exists: the host webview is Android System WebView (Chromium)
// or iOS WKWebView. Setting the UA string changes only the wire-level
// `User-Agent` header, not:
//
//   * `navigator.userAgentData` — Chromium WebView populates this even
//     when the UA is a Firefox UA. Firefox itself doesn't expose the
//     property at all, so we redefine it to return `undefined`.
//   * `navigator.maxTouchPoints` — nonzero on touch devices.
//   * `navigator.platform` — reports `"Linux armv8l"` etc. on Android.
//   * `'ontouchstart' in window` — true on touch devices.
//   * `@media (pointer: coarse)` / `(hover: none)` — match on touch.
//   * `<meta name=viewport>` shipped by the page — defeats `useWideViewPort`.
//
// `Sec-CH-UA-Mobile`, `Sec-CH-UA-Platform`, and `Sec-CH-UA` HTTP request
// headers are emitted by Chromium WebView from a separate UA-metadata
// object — independent of the UA string and unreachable from JS. They
// are overridden separately by `user_agent_metadata_builder.dart`, wired
// into `InAppWebViewSettings.userAgentMetadata` on Android (fork patch
// over `WebSettingsCompat.setUserAgentMetadata`). This shim only
// patches the JS-side surfaces; the wire-level headers live there.
//
// `spoofLayoutViewport=true` adds Android-specific layout spoofs:
// `window.innerWidth`/`outerWidth`/`innerHeight`/`outerHeight` are
// pinned to 1366x768, and the matchMedia wrapper additionally forges
// width-based queries against that fake size. Android Chromium WebView
// does NOT recompute layout when `<meta name=viewport>` content is
// mutated post-parse, so the meta-rewrite below is silently ignored
// for layout — `window.innerWidth` stays at the device's CSS width
// (~412 on a Pixel) and CSS `(max-width: 1300px)` matches, sending
// React Native Web sites like Bluesky down their mobile branch. iOS
// WKWebView re-evaluates on mutation (and synthesizes a desktop
// viewport at the WebKit level via `preferredContentMode=.desktop`
// regardless), so this spoof is gated to Android.

import 'package:webspace/services/user_agent_classifier.dart';

const int _spoofViewportWidth = 1366;
const int _spoofViewportHeight = 768;

/// Build the per-site desktop-mode shim for [userAgent]. The caller is
/// responsible for only invoking this when [isDesktopUserAgent] returns
/// true; the shim assumes the UA is desktop-shaped and uses
/// [inferDesktopUaPlatform] to pick the matching `navigator.platform`.
///
/// [spoofLayoutViewport] controls the Android-only JS-side viewport
/// override (see file header). Pass `true` on Android, `false`
/// elsewhere — iOS already reports a desktop viewport via
/// `preferredContentMode=.desktop`.
String buildDesktopModeShim(
  String userAgent, {
  bool spoofLayoutViewport = false,
}) {
  final platform = inferDesktopUaPlatform(userAgent);
  final navPlatform = navigatorPlatformFor(platform);
  final navPlatformJs = _jsString(navPlatform);
  final spoofW = _spoofViewportWidth;
  final spoofH = _spoofViewportHeight;
  final spoofViewportBlock = spoofLayoutViewport
      ? '''

  // --- Layout viewport spoof (Android host only) ---
  // Android Chromium WebView does not recompute layout when the meta
  // viewport content is mutated post-parse, so the rewrite below
  // updates the attribute string without changing window.innerWidth or
  // CSS width media queries. Pin the JS-visible window size to a
  // typical 1366x768 laptop so React Native Web's Dimensions API and
  // hand-rolled `innerWidth >= N` checks see desktop. The matchMedia
  // wrapper forges (min/max-width) queries against the same value so
  // libraries that go through matchMedia (Bluesky's useWebMediaQueries,
  // CSS-in-JS media-query helpers) get the same answer.
  function defWin(name, val) {
    try {
      Object.defineProperty(window, name, {
        get: asNative(function() { return val; }, name),
        configurable: true
      });
    } catch (e) {}
  }
  defWin('innerWidth', $spoofW);
  defWin('outerWidth', $spoofW);
  defWin('innerHeight', $spoofH);
  defWin('outerHeight', $spoofH);
'''
      : '';

  final widthClauseHelpers = spoofLayoutViewport
      ? '''
      // Width-clause evaluation against the spoofed $spoofW viewport.
      // Returns true/false if the query is purely width-based and we
      // can answer it; null if the query carries any clause we don't
      // recognise (orientation, color, etc.) so we fall through to
      // native matchMedia.
      var WIDTH_RE =
        /\\((max|min)-(?:device-)?width:\\s*(\\d+(?:\\.\\d+)?)\\s*(?:px|em|rem)?\\s*\\)/gi;
      function evalWidthClauses(query) {
        var q = String(query).toLowerCase().trim();
        WIDTH_RE.lastIndex = 0;
        var clauses = [];
        var m;
        while ((m = WIDTH_RE.exec(q)) !== null) {
          clauses.push([m[1], parseFloat(m[2])]);
        }
        if (clauses.length === 0) return null;
        var residual = q.replace(WIDTH_RE, '')
          .replace(/\\b(only|all|screen|and)\\b/g, '')
          .replace(/[(),\\s]+/g, '');
        if (residual.length > 0) return null;
        for (var i = 0; i < clauses.length; i++) {
          var op = clauses[i][0];
          var val = clauses[i][1];
          if (op === 'min' && $spoofW < val) return false;
          if (op === 'max' && $spoofW > val) return false;
        }
        return true;
      }
'''
      : '';

  // Leading "\n" because Dart strips the newline that immediately
  // follows an opening `'''`, and we want this to land on its own
  // line under the FORCE_FALSE check.
  final widthClauseDispatch = spoofLayoutViewport
      ? '\n          var w = evalWidthClauses(query);'
          '\n          if (w !== null) return synthetic(query, w);'
      : '';

  return '''
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
  def('platform', asNative(function() { return $navPlatformJs; }, 'platform'));

  // Remove `'ontouchstart' in window`. Clean desktop Chromium does not
  // expose ontouchstart at all (it's only on Window.prototype on touch
  // builds), so defining it as undefined is the leak we used to ship —
  // `'ontouchstart' in window` would still return true for the
  // own-property. Delete from both window and Window.prototype.
  try { delete window.ontouchstart; } catch (e) {}
  try { delete Window.prototype.ontouchstart; } catch (e) {}
$spoofViewportBlock
  // --- matchMedia wrapper for pointer/hover queries ---
  // Force `(pointer: fine)`, `(hover: hover)`, and the `any-*` variants
  // to match; force `coarse`/`none` opposites not to match. Other queries
  // (width-based, prefers-color-scheme, etc.) fall through to the real
  // implementation — except width queries when spoofLayoutViewport is on,
  // which are answered against the spoofed $spoofW viewport.
  try {
    var origMM = window.matchMedia && window.matchMedia.bind(window);
    if (origMM) {
      var FORCE_TRUE =
        /\\((?:any-)?pointer:\\s*fine\\)|\\((?:any-)?hover:\\s*hover\\)/i;
      var FORCE_FALSE =
        /\\((?:any-)?pointer:\\s*coarse\\)|\\((?:any-)?hover:\\s*none\\)/i;
$widthClauseHelpers
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
          if (FORCE_FALSE.test(query)) return synthetic(query, false);$widthClauseDispatch
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
  // viewport meta to a desktop-ish width=$spoofW (a common laptop width)
  // as soon as it appears. Must clear the widest "desktop" breakpoint a
  // mainstream site uses; Bluesky gates `isDesktop` on
  // `(min-width: 1300px)` and treats 800-1299 as tablet, so a viewport
  // <=1299 ships the tablet layout. iOS WKWebView re-evaluates the
  // meta on mutation; Android Chromium WebView does not, which is why
  // spoofLayoutViewport additionally pins window.innerWidth above.
  var VIEWPORT_CONTENT = 'width=$spoofW, initial-scale=1.0';
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

  // Intentionally NOT spoofing `window.devicePixelRatio` or `screen.width`.
  // DPR is orthogonal to desktop-vs-mobile layout — modern retina displays
  // report dpr >= 2 — and screen.* would conflict with the
  // anti-fingerprinting shim's screen overrides.
})();
''';
}

/// JS-string-literal escape for ASCII platform tokens. Restricted in scope:
/// the only values we pass in are `Linux x86_64` / `MacIntel` / `Win32`
/// (no embedded quotes), but this keeps the embedding correct if that
/// ever changes.
String _jsString(String s) {
  final buf = StringBuffer('"');
  for (final rune in s.runes) {
    final ch = String.fromCharCode(rune);
    switch (ch) {
      case '\\':
        buf.write(r'\\');
        break;
      case '"':
        buf.write(r'\"');
        break;
      case '\n':
        buf.write(r'\n');
        break;
      case '\r':
        buf.write(r'\r');
        break;
      case '\t':
        buf.write(r'\t');
        break;
      default:
        buf.write(ch);
    }
  }
  buf.write('"');
  return buf.toString();
}
