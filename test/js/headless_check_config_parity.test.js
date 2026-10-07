// Headless-check posture parity (NOTIF-016).
//
// A background wake opens a site with no webview in a headless one, built
// from `WebViewModel.headlessCheckConfig`. That config is written out beside
// `getWebView`'s rather than shared with it, because `getWebView` threads a
// screen's worth of UI callbacks through the same constructor. So the two can
// drift: a per-site field added to the site's own webview and not here would
// let a background check reach the network without it, which is the leak the
// nested-webview rule in CLAUDE.md exists to stop.
//
// Every argument `getWebView` passes to `WebViewConfig(` must also be passed
// by `headlessCheckConfig`, unless it is listed below as UI-only: a callback
// or state that serves a visible webview and means nothing headless.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/web_view_model.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const UI_ONLY = new Set([
  'key',
  // A headless check loads its own URL once; there is no restore and no
  // proxy-ordering deferral to wait out (the wake applies the route first).
  'deferInitialLoad',
  'backForwardGestures',
  'onConfirmScriptFetch',
  'onUntrustedCertificate',
  'onHttpAuthRequest',
  'onExternalSchemeUrl',
  'onLinkLongPress',
  'onProtectedMediaRequest',
  'onCameraDecision',
  'onMicrophoneDecision',
  'onScreenShareDecision',
  'pullToRefreshController',
  'pullToRefreshGate',
  'onWindowRequested',
  'onUnproxiedNavigationBlocked',
  'shouldOverrideUrlLoading',
  'onReloadIssued',
  'onMainFrameLoad',
  'onLoadingChanged',
  'onProgressChanged',
  'onUrlChanged',
  'cookieManager',
  'containerCookieManager',
  'onCookiesChanged',
  'onFindResult',
  'onHtmlLoaded',
  'shouldFetchHtml',
  'initialHtml',
  'onRendererGone',
  'onPageCommitVisible',
  'passkeys',
  // Watchers that learn from the page and write it back to the site's
  // settings; a background check leaves the settings as they are.
  'siteIcon',
  'siteSearch',
  'onConsoleMessage',
]);

/// The top-level named arguments of the first `WebViewConfig(` call after
/// [from], found by tracking bracket depth so nested calls do not count.
function configArgs(from) {
  const start = src.indexOf('WebViewConfig(', from);
  assert.ok(start >= 0, `no WebViewConfig( after offset ${from} in ${rel}`);
  let depth = 0;
  let i = start + 'WebViewConfig'.length;
  const names = new Set();
  let token = '';
  let inString = null;
  for (; i < src.length; i++) {
    const ch = src[i];
    if (inString) {
      if (ch === '\\') { i++; continue; }
      if (ch === inString) inString = null;
      continue;
    }
    if (ch === "'" || ch === '"') { inString = ch; continue; }
    if (ch === '/' && src[i + 1] === '/') {
      i = src.indexOf('\n', i);
      continue;
    }
    if ('([{'.includes(ch)) { depth++; token = ''; continue; }
    if (')]}'.includes(ch)) {
      depth--;
      if (depth === 0) break;
      token = '';
      continue;
    }
    if (depth === 1 && ch === ':' && /^[A-Za-z_]\w*$/.test(token.trim())) {
      names.add(token.trim());
      token = '';
      continue;
    }
    if (depth === 1 && ch === ',') { token = ''; continue; }
    if (depth === 1) token += ch;
  }
  return names;
}

const getWebView = src.indexOf('Widget getWebView(');
const headless = src.indexOf('WebViewConfig headlessCheckConfig(');

test('both configs are where this gate looks', () => {
  assert.ok(getWebView >= 0, `${rel} must define getWebView`);
  assert.ok(headless >= 0, `${rel} must define headlessCheckConfig`);
});

test('the headless check carries every per-site field the site webview does',
  () => {
    const site = configArgs(getWebView);
    const check = configArgs(headless);
    assert.ok(site.size > 30, `parsed only ${site.size} arguments from getWebView`);
    const missing = [...site].filter((n) => !check.has(n) && !UI_ONLY.has(n));
    assert.deepEqual(missing, [],
      `headlessCheckConfig must pass ${missing.join(', ')} ` +
      '(or the field is UI-only and belongs in UI_ONLY here)');
  });

test('UI_ONLY names only fields the site webview still passes', () => {
  const site = configArgs(getWebView);
  const stale = [...UI_ONLY].filter((n) => !site.has(n));
  assert.deepEqual(stale, [], `UI_ONLY lists ${stale.join(', ')}, which getWebView no longer passes`);
});
