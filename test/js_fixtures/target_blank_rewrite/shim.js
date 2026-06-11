(function() {
  if (window.__webspaceTargetBlankHooked) return;
  window.__webspaceTargetBlankHooked = true;
  try {
    function opensNewWindow(t) {
      if (!t) return false;
      t = ('' + t).toLowerCase();
      return t === '_blank' || t === '_new';
    }
    function isHttpAnchor(el) {
      if (!el || el.tagName !== 'A') return false;
      var href = '';
      try { href = el.href || el.getAttribute('href') || ''; } catch (_) {}
      if (typeof href !== 'string') return false;
      return href.indexOf('http://') === 0 || href.indexOf('https://') === 0;
    }
    var listener = function(e) {
      var el = e.target;
      // Walk up so a click on a child of the anchor (icon, span) still
      // resolves to the <a>.
      while (el && el !== document && el.tagName !== 'A') {
        el = el.parentNode;
      }
      if (!el || el === document || el.tagName !== 'A') return;
      try {
        if (!opensNewWindow(el.getAttribute('target'))) return;
        if (!isHttpAnchor(el)) return;
        el.setAttribute('target', '_self');
      } catch (_) {}
    };
    document.addEventListener('click', listener, true);
  } catch (_) {}
})();
