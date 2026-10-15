// Unscoped container cookie-read gate (DL-003, CONT-005).
//
// Under the container engine every site's cookies live in its own native jar
// and the default jar is unused. `inapp.CookieManager` resolves which jar an
// op addresses from the `webViewController:` argument — omit it and the op
// silently lands in the default jar, which for a container-bound site is
// empty. Reads come back with nothing and writes go somewhere no WebView
// reads from.
//
// That is not a crash; it is a logged-out request. The HTTP download path hit
// exactly this: `getCookies(url:)` with no controller returned zero cookies
// for a site the user was signed in to, so the re-issued GET went out
// anonymous and authenticated downloads (NotebookLM audio, any signed-in
// attachment) came back 403 while the same URL downloaded fine in the page.
//
// Structural rather than behavioral: reproducing it needs a device with the
// container engine active and a live signed-in session, which no CI tier here
// has. The rule below is what keeps the class closed: every cookie op on the
// plugin carries the WebView it belongs to.
//
// Every op reaches the plugin through `cookieChannel`
// (lib/services/cookie_manager.dart), the one place that names what the
// channel fails with (CONT-009), so the rule reads those calls; the first test
// keeps a direct handle on the plugin from slipping past both.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code } = require('./helpers/source');

/// Ops whose target jar the plugin resolves from `webViewController:`.
const SCOPED_OPS = [
  'getCookies(',
  'getCookie(',
  'setCookie(',
  'deleteCookie(',
];

/// Holds the plugin's handle and the shared jar's wrapper, whose ops address
/// the default jar by design: under the legacy engine that is every site's.
const GUARD = 'lib/services/cookie_manager.dart';

/// Every call through the guard outside it, as
/// `<text from cookieChannel( to the statement's semicolon>`.
function channelCalls() {
  const out = [];
  for (const rel of dartFiles()) {
    if (rel === GUARD) continue;
    const source = code(read(rel));
    const marker = 'cookieChannel(';
    let at = source.indexOf(marker);
    while (at !== -1) {
      const end = source.indexOf(';', at);
      out.push({
        rel,
        line: source.slice(0, at).split('\n').length,
        text: source.slice(at, end === -1 ? source.length : end),
      });
      at = source.indexOf(marker, at + marker.length);
    }
  }
  return out;
}

test('the plugin cookie manager is reached only through cookieChannel', () => {
  const direct = dartFiles().filter(
    (rel) => rel !== GUARD && code(read(rel)).includes('CookieManager.instance()'),
  );
  assert.deepEqual(
    direct,
    [],
    'a direct inapp.CookieManager.instance() bypasses cookieChannel: its ' +
      'failures go unnamed and its scope goes unread by the test below',
  );
  const handles = code(read(GUARD)).match(/CookieManager\.instance\(\)/g) ?? [];
  assert.equal(handles.length, 1, `${GUARD} holds the plugin's one handle`);
});

test('every cookie op on the plugin names its WebView (CONT-006)', () => {
  const calls = channelCalls();
  // Not vacuous: the container jar's ops and the download's read are here.
  for (const rel of [
    'lib/services/container_cookie_manager.dart',
    'lib/services/webview_downloads.dart',
  ]) {
    assert.ok(
      calls.some((c) => c.rel === rel && SCOPED_OPS.some((op) => c.text.includes(op))),
      `${rel} no longer makes a scoped op through cookieChannel; re-point the gate`,
    );
  }
  const unscoped = calls.filter(
    ({ text }) =>
      SCOPED_OPS.some((op) => text.includes(op)) &&
      !text.includes('webViewController:'),
  );

  assert.deepEqual(
    unscoped.map((s) => `${s.rel}:${s.line}`),
    [],
    'a cookie op through cookieChannel must pass webViewController:; ' +
      'without it the op addresses the default jar, which is empty for ' +
      'every container-bound site',
  );
});

test('the HTTP download path reads cookies through the downloading WebView', () => {
  // DL-003: the re-issued GET only carries the site's session if the read is
  // scoped to the WebView that raised onDownloadStartRequest. The controller
  // has to reach the handler for that to be possible at all, so assert both
  // halves.
  const webview = read('lib/services/webview_downloads.dart');

  assert.match(
    webview,
    /static Future<void> _handleHttpDownload\(\s*inapp\.InAppWebViewController controller,/,
    '_handleHttpDownload must take the controller that started the download',
  );

  const body = webview.slice(webview.indexOf('_handleHttpDownload(\n'));
  const cookieRead = body.slice(body.indexOf('cookieChannel('));
  assert.match(
    cookieRead.slice(0, cookieRead.indexOf(';')),
    /webViewController: controller/,
    'the download cookie read must be scoped to the downloading WebView',
  );
});
