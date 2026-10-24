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
// A key reaches only the document of the frame that holds focus, while
// spatial navigation may move focus or scroll in any document above it. So a
// frame passes an arrow it had no use for to its parent with the time it was
// pressed, the parent waits two frames of its own and passes it on if nothing
// moved or scrolled there since, and only the top document calls the bridge.
// A parent takes an arrow only from the frame holding its focus, the one a
// key goes to.
(function() {
  try {
    var DIRECTIONS = {
      ArrowUp: 'up',
      ArrowDown: 'down',
      ArrowLeft: 'left',
      ArrowRight: 'right',
    };
    var NAMES = Object.keys(DIRECTIONS).map(function(key) { return DIRECTIONS[key]; });
    var RELAY = '__wsRemoteEdge';
    var TEXT_INPUTS = /^(text|search|email|url|tel|password|number|date|datetime-local|month|time|week)$/;
    var scrolls = 0;
    var scrolledAt = -Infinity;
    document.addEventListener('scroll', function() {
      scrolls++;
      scrolledAt = Date.now();
    }, true);

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

    function passOn(direction, focused, since) {
      if (document.activeElement !== focused) return;
      if (window === window.top) {
        var iaw = window.flutter_inappwebview;
        if (!iaw || typeof iaw.callHandler !== 'function') return;
        iaw.callHandler(CONFIG.handler, direction);
        return;
      }
      var report = {};
      report[RELAY] = { direction: direction, since: since };
      window.parent.postMessage(report, '*');
    }

    window.addEventListener('keydown', function(e) {
      var direction = DIRECTIONS[e.key];
      if (!direction || e.repeat) return;
      if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return;
      var focused = document.activeElement;
      if (editing(focused)) return;
      var at = { x: window.scrollX, y: window.scrollY, scrolls: scrolls };
      var since = Date.now();
      afterFrames(2, function() {
        if (e.defaultPrevented) return;
        if (scrolls !== at.scrolls) return;
        if (window.scrollX !== at.x || window.scrollY !== at.y) return;
        passOn(direction, focused, since);
      });
    }, true);

    window.addEventListener('message', function(e) {
      var report = e.data && e.data[RELAY];
      if (!report || typeof report.since !== 'number') return;
      if (NAMES.indexOf(report.direction) === -1) return;
      var frame = document.activeElement;
      if (!frame || !e.source || frame.contentWindow !== e.source) return;
      afterFrames(2, function() {
        if (scrolledAt >= report.since) return;
        passOn(report.direction, frame, report.since);
      });
    });
  } catch (e) {}
})();
