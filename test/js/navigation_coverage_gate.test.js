// Every top-frame load a site webview issues is asked of its coverage gate
// first (LEAK-010, LEAK-016). The page's own navigations meet it in
// shouldOverrideUrlLoading; a load the app reissues through the plugin's raw
// controller meets it as `refused(url)` in the condition guarding the call,
// because Android shows a programmatic load to no navigation callback.
// Rung 5: the plugin's loadUrl takes any URL, and no type can say that its
// caller asked. A reissue of the URL the gate just passed, on its host, is
// listed with that reason.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const FACTORY = 'lib/services/webview.dart';

const SAME_HOST = {
  'out.load!': 'the HTTPS upgrade falling back to the http URL the gate passed',
  'upgrade.load!': 'the HTTPS upgrade of the URL the gate passed',
  'upgradeFailure.load!': 'the http URL an upgrade of a passed URL replaced',
  originalUrl: 'the iOS Universal Link reissue of the URL the gate passed',
};

const LOAD = /controller\.loadUrl\(\s*urlRequest:\s*inapp\.URLRequest\(\s*url:\s*(?:inapp\.WebUri\(([^()]+)\)|(\w+))/g;

/** The URLs a raw load in [src] issues without asking the gate. */
function unasked(src) {
  const out = [];
  for (const m of src.matchAll(LOAD)) {
    const target = (m[1] ?? m[2]).trim();
    if (target in SAME_HOST) continue;
    const guard = src.lastIndexOf('if (', m.index);
    const condition = guard < 0 ? '' : src.slice(guard, src.indexOf('{', guard));
    if (!condition.includes(`refused(${target})`)) out.push(target);
  }
  return out;
}

test('every raw load the factory reissues asks the gate (LEAK-016)', () => {
  const src = read(FACTORY);
  assert.ok([...src.matchAll(LOAD)].length > Object.keys(SAME_HOST).length,
    'no raw loads found; the pattern no longer reads the factory');
  assert.deepEqual(unasked(src), [],
    'guard the load with `if (... !refused(url))`, or list it with why it '
    + 'carries the host of the URL the gate just passed');
});

test('the page, its frames and the app\'s own loads meet the gate', () => {
  const src = read(FACTORY);
  for (const marker of [
    'if (refused(url)) return inapp.NavigationActionPolicy.CANCEL;',
    'if (coverageGate.evaluateFrame(url) case final Uncovered why) {',
    'refuses: refused,',
    'final firstLoadRefused =\n        refusesLoad(binding, url: config.initialUrl);',
  ]) {
    assert.ok(src.includes(marker), `${FACTORY} lacks ${marker}`);
  }
  assert.ok(read('lib/services/webview_controller.dart')
    .includes("if (_refuses(request.url?.rawValue ?? '')) return;"),
  'PlatformWebViewController.loadRequest must ask before it loads');
});

test('the gate catches the mistake it is for', () => {
  const planted = `
    if (allow) {
      unawaited(controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(resolved))));
    }
    if (allow && !refused(url)) {
      unawaited(controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(cleaned))));
    }
    if (!refused(next)) {
      unawaited(controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(next))));
    }
    unawaited(controller.loadUrl(urlRequest: inapp.URLRequest(url: inapp.WebUri(upgrade.load!))));`;
  assert.deepEqual(unasked(planted), ['resolved', 'cleaned']);
});
