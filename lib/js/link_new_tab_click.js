// A link clicked with the platform's new-tab modifier (Command on macOS,
// Control elsewhere) or with the middle button asks CONFIG.handler for the
// link in a new tab, as the link menu's "Open in new tab" does. The engine's
// own answer would be a new window, which the app runs as a plain tap, so the
// click's default is prevented; the page's own handlers still see it.
(function() {
  if (window.__wsLinkNewTabClick) return;
  window.__wsLinkNewTabClick = true;
  try {
    var MODIFIER = CONFIG.modifier;

    function linkOf(target) {
      var el = target;
      while (el && el.nodeType !== 1) el = el.parentNode;
      var a = el && el.closest ? el.closest('a[href]') : null;
      if (!a) return null;
      var href;
      try { href = a.href; } catch (_) { return null; }
      if (typeof href !== 'string') return null;
      if (href.indexOf('http://') !== 0 && href.indexOf('https://') !== 0) return null;
      return href;
    }

    function ask(e) {
      if (e.defaultPrevented) return;
      var href = linkOf(e.target);
      if (!href) return;
      var iaw = window.flutter_inappwebview;
      if (!iaw || typeof iaw.callHandler !== 'function') return;
      e.preventDefault();
      iaw.callHandler(CONFIG.handler, href);
    }

    document.addEventListener('click', function(e) {
      if (e.button !== 0 || !e[MODIFIER]) return;
      ask(e);
    }, true);
    document.addEventListener('auxclick', function(e) {
      if (e.button !== 1) return;
      ask(e);
    }, true);
  } catch (_) {}
})();
