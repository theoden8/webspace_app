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
// has. The rule below is what keeps the class closed — every direct cookie op
// on the plugin singleton carries the WebView it belongs to.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

/// Ops whose target jar the plugin resolves from `webViewController:`.
const SCOPED_OPS = [
  'getCookies(',
  'getCookie(',
  'setCookie(',
  'deleteCookie(',
];

function dartSources(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...dartSources(full));
    else if (entry.name.endsWith('.dart')) out.push(full);
  }
  return out;
}

/// Strip `//` comments so a semicolon or an op name inside prose can't end or
/// fake a statement. Block comments are left alone: none of the call sites
/// this gate reads sit inside one.
function stripLineComments(source) {
  return source
    .split('\n')
    .map((line) => {
      const i = line.indexOf('//');
      return i === -1 ? line : line.slice(0, i);
    })
    .join('\n');
}

/// Every statement that reaches the plugin singleton directly, as
/// `<text from the instance() call to the statement's semicolon>`.
function singletonStatements() {
  const out = [];
  for (const file of dartSources(path.join(repoRoot, 'lib'))) {
    const rel = path.relative(repoRoot, file);
    const source = stripLineComments(fs.readFileSync(file, 'utf8'));
    const marker = 'CookieManager.instance()';
    let at = source.indexOf(marker);
    while (at !== -1) {
      const end = source.indexOf(';', at);
      const text = source.slice(at, end === -1 ? source.length : end);
      out.push({
        rel,
        line: source.slice(0, at).split('\n').length,
        text,
      });
      at = source.indexOf(marker, at + marker.length);
    }
  }
  return out;
}

test('every direct cookie op on the plugin singleton names its WebView', () => {
  // A bare `final _manager = CookieManager.instance();` field is fine: it is a
  // wrapper's handle, and which jar its calls address is decided by the
  // wrapper the host picked (CookieManager for legacy, ContainerCookieManager
  // for containers). Only a statement that performs the op itself is bound by
  // this rule.
  const unscoped = singletonStatements().filter(
    ({ text }) =>
      SCOPED_OPS.some((op) => text.includes(op)) &&
      !text.includes('webViewController:'),
  );

  assert.deepEqual(
    unscoped.map((s) => `${s.rel}:${s.line}`),
    [],
    'a cookie op on inapp.CookieManager.instance() must pass ' +
      'webViewController: — without it the op addresses the default jar, ' +
      "which is empty for every container-bound site",
  );
});

test('the HTTP download path reads cookies through the downloading WebView', () => {
  // DL-003: the re-issued GET only carries the site's session if the read is
  // scoped to the WebView that raised onDownloadStartRequest. The controller
  // has to reach the handler for that to be possible at all, so assert both
  // halves.
  const webview = fs.readFileSync(
    path.join(repoRoot, 'lib/services/webview.dart'),
    'utf8',
  );

  assert.match(
    webview,
    /static Future<void> _handleHttpDownload\(\s*inapp\.InAppWebViewController controller,/,
    '_handleHttpDownload must take the controller that started the download',
  );

  const body = webview.slice(webview.indexOf('_handleHttpDownload(\n'));
  const read = body.slice(body.indexOf('CookieManager.instance()'));
  assert.match(
    read.slice(0, read.indexOf(';')),
    /webViewController: controller/,
    'the download cookie read must be scoped to the downloading WebView',
  );
});
