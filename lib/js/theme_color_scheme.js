// Theme / color-scheme JavaScript shim.
//
// Answers the `prefers-color-scheme` feature of a matchMedia query from the
// app theme, sets the `<meta name="color-scheme">` tag, and runs the page's
// `addEventListener('change', ...)` callbacks when the app theme flips — so
// a site that styles via CSS media queries follows the in-app theme instead
// of the host OS preference.
//
// Only that feature is the app's: each `(prefers-color-scheme: X)` in the
// query becomes `(grid: 0)` (always true on a bitmap screen) or `(grid: 1)`
// (always false), and the engine evaluates the rewritten query, so the rest
// of it (`not`, `only`, `,` lists, `prefers-contrast` and every other
// feature) answers as it would without the shim (accessibility spec).
//
// Theme value: 'light' or 'dark'. The app's 'system' is resolved in Dart
// from the platform brightness (toldScheme), so the page and the chrome
// agree.
(function() {
  // @include _native_fn.js

  const actualTheme = CONFIG.theme;
  window.__appThemePreference = actualTheme;
  if (!window.__originalMatchMedia) {
    window.__originalMatchMedia = window.matchMedia.bind(window);
  }
  var FEATURE = /\(\s*prefers-color-scheme\s*(?::\s*([a-z-]+)\s*)?\)/gi;
  var schemed = function(query) {
    FEATURE.lastIndex = 0;
    return FEATURE.test(query);
  };
  var rewrite = function(query) {
    var appIsDark = window.__appThemePreference === 'dark';
    return query.replace(FEATURE, function(feature, value) {
      if (value === undefined) return '(grid: 0)';
      switch (value.toLowerCase()) {
        case 'dark': return appIsDark ? '(grid: 0)' : '(grid: 1)';
        case 'light': return appIsDark ? '(grid: 1)' : '(grid: 0)';
        default: return feature;
      }
    });
  };
  var engineList = function(query) {
    return window.__originalMatchMedia(rewrite(query));
  };
  var notify = function(item) {
    var matches = engineList(item.query).matches;
    if (matches === item.last) return;
    item.last = matches;
    try { item.listener({ type: 'change', matches: matches, media: item.query }); } catch (e) {}
  };
  var follow = function(item) {
    if (item.engine && typeof item.engine.removeEventListener === 'function') {
      item.engine.removeEventListener('change', item.onEngineChange);
    }
    item.engine = engineList(item.query);
    item.onEngineChange = function() { notify(item); };
    if (typeof item.engine.addEventListener === 'function') {
      item.engine.addEventListener('change', item.onEngineChange);
    }
  };
  var _patchedMM = function matchMedia(query) {
    var text = String(query);
    if (!schemed(text)) return window.__originalMatchMedia(query);
    var list = {
      get matches() { return engineList(text).matches; },
      media: text,
      onchange: null,
      addEventListener: function(type, listener) {
        if (type !== 'change' || typeof listener !== 'function') return;
        window.__themeChangeListeners = window.__themeChangeListeners || [];
        var item = { list: list, query: text, listener: listener, last: list.matches };
        follow(item);
        window.__themeChangeListeners.push(item);
      },
      removeEventListener: function(type, listener) {
        if (type !== 'change' || !window.__themeChangeListeners) return;
        window.__themeChangeListeners = window.__themeChangeListeners.filter(function(item) {
          if (item.list !== list || item.listener !== listener) return true;
          if (item.engine && typeof item.engine.removeEventListener === 'function') {
            item.engine.removeEventListener('change', item.onEngineChange);
          }
          return false;
        });
      },
      addListener: function(listener) { this.addEventListener('change', listener); },
      removeListener: function(listener) { this.removeEventListener('change', listener); }
    };
    return list;
  };
  asNative(_patchedMM, 'matchMedia');
  window.matchMedia = _patchedMM;
  // The shim is a DOCUMENT_START user script, where the parser has made
  // <html> but not yet <head> — and a color-scheme meta only counts inside
  // the head. Touching either unguarded threw here, which killed the rest of
  // this shim (the listener replay below) on every page load.
  var applyColorScheme = function() {
    if (!document.documentElement) return false;
    document.documentElement.style.colorScheme = actualTheme;
    let metaTag = document.querySelector('meta[name="color-scheme"]');
    if (!metaTag) {
      if (!document.head) return false;
      metaTag = document.createElement('meta');
      metaTag.name = 'color-scheme';
      document.head.appendChild(metaTag);
    }
    metaTag.content = actualTheme;
    return true;
  };
  if (!applyColorScheme()) {
    document.addEventListener('DOMContentLoaded', applyColorScheme, { once: true });
  }
  if (window.__themeChangeListeners) {
    window.__themeChangeListeners.forEach(function(item) {
      follow(item);
      notify(item);
    });
  }
})();
