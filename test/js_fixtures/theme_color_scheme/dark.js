(function() {
  let actualTheme = 'dark';
  if (actualTheme === 'system') {
    actualTheme = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  window.__appThemePreference = actualTheme;
  if (!window.__originalMatchMedia) {
    window.__originalMatchMedia = window.matchMedia.bind(window);
  }
  window.matchMedia = function(query) {
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
