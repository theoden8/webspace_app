/// Capture-phase click shim that rewrites new-window anchor targets
/// (`target="_blank"` / `_new`) to `_self` for http(s) links.
///
/// Why this exists: the app enables `supportMultipleWindows` (Cloudflare
/// Turnstile and other challenges need it). A side effect is that on
/// Android a `target="_blank"` link tap is routed to
/// `WebChromeClient.onCreateWindow` instead of `shouldOverrideUrlLoading`.
/// In that path the user-gesture flag (`createWindowAction.hasGesture`) is
/// unreliable — Android frequently reports `false` for a genuine tap — and
/// the request URL is sometimes empty. The nested-url-blocking engine then
/// reads "no gesture" and silently cancels the navigation (NESTED-004), so
/// the link does nothing (issue #405). iOS has the same divergence:
/// `target="_blank"` taps often only fire `onCreateWindow`.
///
/// Rewriting the target to `_self` at capture phase (before the browser's
/// default action and before site click handlers) routes the tap through
/// the normal top-level navigation path, where the per-request gesture
/// signal IS reliable. The decision engine then sees a real gesture and
/// opens the cross-domain destination in a nested webview as intended.
///
/// Scope and safety:
///   * Only http(s) anchors are touched. `blob:`/`data:`/external-scheme
///     and download links (handled by `blobDownloadClickInterceptScript`)
///     are left alone.
///   * Same-domain `target="_blank"` links already loaded in the current
///     webview via the `onCreateWindow` allow path, so rewriting them to
///     `_self` keeps the identical in-place behavior — no regression.
///   * Script-driven `window.open()` (captcha popups, analytics) is not an
///     anchor target and is untouched; it still flows through
///     `onCreateWindow` and its existing gesture/captcha filtering.
const String targetBlankRewriteScript = r'''
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
''';
