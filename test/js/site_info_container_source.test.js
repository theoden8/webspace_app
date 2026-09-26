// Site info sheet gate (NAV-011).
//
// The sheet names the container a page's webview binds. It is only true if it
// is computed by the rule the factory binds by, from the inputs that webview's
// WebViewConfig was given. A sheet built from other inputs (the raw
// `incognito` where the config reads `effectiveIncognito`, or the siteId where
// an archive site binds its archiveContainerId) names a container the page
// does not use, which is worse than no sheet.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const root = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(root, rel), 'utf8');
const webview = read('lib/services/webview.dart');
const model = read('lib/web_view_model.dart');
const main = read('lib/main.dart');
const nested = read('lib/screens/inappbrowser.dart');

// The argument list of the call whose `(` is the first at or after [from].
function callText(text, from) {
  const open = text.indexOf('(', from);
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === '(') depth++;
    else if (text[i] === ')' && --depth === 0) return text.slice(open + 1, i);
  }
  assert.fail(`unbalanced parentheses at offset ${from}`);
}

test('the factory binds through containerIdFor', () => {
  const create = blockAfter(webview, '}) _bindingFor(WebViewConfig config) {', null, 'webview.dart');
  const at = create.indexOf('final containerId = containerIdFor(');
  assert.notEqual(at, -1, 'the binding must follow the rule the sheet reports');
  const args = callText(create, at);
  assert.match(args, /siteId: config\.siteId/);
  assert.match(args, /archiveContainerId: config\.archiveContainerId/);
  assert.match(args, /incognito: config\.incognito/);
});

test('every URL bar offers site info', () => {
  for (const [rel, src] of [['lib/main.dart', main], ['lib/screens/inappbrowser.dart', nested]]) {
    const calls = [...src.matchAll(/\bUrlBar\(/g)];
    assert.ok(calls.length > 0, `${rel} has no URL bar`);
    for (const m of calls) {
      assert.match(callText(src, m.index), /onSiteInfo:/, `a URL bar in ${rel} has no info button`);
    }
  }
});

test('the main sheet reads the inputs of the site webview config', () => {
  const config = callText(model, model.indexOf('webview = WebViewFactory.createWebView('));
  assert.match(config, /archiveContainerId: archiveContainerId,/);
  assert.match(config, /incognito: effectiveIncognito,/);
  const bar = callText(main, main.search(/\bUrlBar\(/));
  const rule = callText(bar, bar.indexOf('containerIdFor('));
  assert.match(rule, /siteId: model\.siteId/);
  assert.match(rule, /archiveContainerId: model\.archiveContainerId/);
  assert.match(rule, /incognito: model\.effectiveIncognito/);
});

test('the nested sheet reads the inputs of the nested webview config', () => {
  const config = callText(nested, nested.indexOf('config: WebViewConfig('));
  assert.match(config, /siteId: widget\.siteId,/);
  assert.match(config, /incognito: widget\.incognito,/);
  assert.match(config, /archiveContainerId: widget\.archiveContainerId,/);
  const show = blockAfter(nested, '  void _showSiteInfo() {', null, 'inappbrowser.dart');
  const rule = callText(show, show.indexOf('containerIdFor('));
  assert.match(rule, /siteId: widget\.siteId/);
  assert.match(rule, /archiveContainerId: widget\.archiveContainerId/,
    'an archived site\'s nested screen binds its opaque container (ARCH-007)');
  assert.match(rule, /incognito: widget\.incognito/);
});
