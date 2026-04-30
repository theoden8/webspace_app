(function() {
  // --- Function.prototype.toString hardening (shared with the other shims
  // via window.__wsFnStubs / __wsFnToStringPatched). Without it, a
  // fingerprinter calling Function.prototype.toString on window.matchMedia
  // would read back our wrapper source instead of "[native code]".
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

  let actualTheme = 'light';
  if (actualTheme === 'system') {
    actualTheme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  window.__appThemePreference = actualTheme;
  if (!window.__originalMatchMedia) {
    window.__originalMatchMedia = window.matchMedia.bind(window);
  }
  var _patchedMM = function matchMedia(query) {
    const originalResult = window.__originalMatchMedia(query);
    if (query.includes('prefers-color-scheme')) {
      const isDarkQuery = query.includes('dark');
      const isLightQuery = query.includes('light');
      const appIsDark = window.__appThemePreference === 'dark';
      let matches = isDarkQuery ? appIsDark : (isLightQuery ? !appIsDark : false);
      return {
        matches: matches,
        media: query,
        onchange: null,
        addEventListener: function(type, listener) {
          if (type === 'change') {
            window.__themeChangeListeners = window.__themeChangeListeners || [];
            window.__themeChangeListeners.push({ query: query, listener: listener });
          }
        },
        removeEventListener: function(type, listener) {
          if (type === 'change' && window.__themeChangeListeners) {
            window.__themeChangeListeners = window.__themeChangeListeners.filter(item => item.listener !== listener);
          }
        },
        addListener: function(listener) { this.addEventListener('change', listener); },
        removeListener: function(listener) { this.removeEventListener('change', listener); }
      };
    }
    return originalResult;
  };
  asNative(_patchedMM, 'matchMedia');
  window.matchMedia = _patchedMM;
  let metaTag = document.querySelector('meta[name="color-scheme"]');
  if (!metaTag) {
    metaTag = document.createElement('meta');
    metaTag.name = 'color-scheme';
    document.head.appendChild(metaTag);
  }
  metaTag.content = actualTheme;
  document.documentElement.style.colorScheme = actualTheme;
  if (window.__themeChangeListeners) {
    window.__themeChangeListeners.forEach(item => {
      const isDarkQuery = item.query.includes('dark');
      const isLightQuery = item.query.includes('light');
      const appIsDark = window.__appThemePreference === 'dark';
      let matches = isDarkQuery ? appIsDark : (isLightQuery ? !appIsDark : false);
      try { item.listener({ matches: matches, media: item.query }); } catch (e) {}
    });
  }
})();
