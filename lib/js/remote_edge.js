// NAV-016: names to the CONFIG.handler bridge handler a D-pad arrow the page
// had no use for, so the app can move focus out of the page toward its app
// bar or tab strip. Installed only where a TV remote drives the device.
//
// The page has the key first and the webview's spatial navigation after it,
// so the answer waits two frames: an arrow that moved focus, scrolled
// anything or that the page took (preventDefault) was the page's. In a text
// field the arrows move the caret, so they stay there. A held arrow never
// leaves: scrolling to the end of a page is not asking to leave it.
//
// Main frame only: a key pressed in a frame never reaches the top document.
(function() {
  try {
    if (window !== window.top) return;
    var DIRECTIONS = {
      ArrowUp: 'up',
      ArrowDown: 'down',
      ArrowLeft: 'left',
      ArrowRight: 'right',
    };
    var TEXT_INPUTS = /^(text|search|email|url|tel|password|number|date|datetime-local|month|time|week)$/;
    var scrolls = 0;
    document.addEventListener('scroll', function() { scrolls++; }, true);

    function editing(el) {
      if (!el) return false;
      if (el.isContentEditable) return true;
      var tag = el.tagName;
      if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
      return tag === 'INPUT' && TEXT_INPUTS.test((el.type || 'text').toLowerCase());
    }

    function afterFrames(count, then) {
      if (count === 0) return then();
      window.requestAnimationFrame(function() { afterFrames(count - 1, then); });
    }

    window.addEventListener('keydown', function(e) {
      var direction = DIRECTIONS[e.key];
      if (!direction || e.repeat) return;
      if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
      var focused = document.activeElement;
      if (editing(focused)) return;
      var at = { x: window.scrollX, y: window.scrollY, scrolls: scrolls };
      afterFrames(2, function() {
        if (e.defaultPrevented) return;
        if (document.activeElement !== focused) return;
        if (scrolls !== at.scrolls) return;
        if (window.scrollX !== at.x || window.scrollY !== at.y) return;
        var iaw = window.flutter_inappwebview;
        if (!iaw || typeof iaw.callHandler !== 'function') return;
        iaw.callHandler(CONFIG.handler, direction);
      });
    }, true);
  } catch (e) {}
})();
