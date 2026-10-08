// Site info sheet gate (NAV-011).
//
// The sheet names the container a page's webview binds. It is only true if it
// is computed by the rule the factory binds by, from the posture that webview's
// WebViewConfig was given. A sheet built from other inputs (the raw
// `incognito` where the config reads `effectiveIncognito`, or the siteId where
// an archive site binds its archiveContainerId) names a container the page
// does not use, which is worse than no sheet.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter, callArgs } = require('./helpers/source');

const webview = read('lib/services/webview.dart');
const model = read('lib/web_view_model.dart');
const main = read('lib/screens/webspace_page.dart');
const nested = read('lib/screens/inappbrowser.dart');

test('the factory binds through containerIdFor', () => {
  assert.match(webview,
    /static StoreBinding bindingFor\(WebViewConfig config\) =>\s*storeBinding\(config\.posture\);/);
  const create = blockAfter(webview, 'static StoreBinding storeBinding(SitePosture posture) {',
    null, 'webview.dart');
  const at = create.indexOf('final containerId = containerIdFor(');
  assert.notEqual(at, -1, 'the binding must follow the rule the sheet reports');
  const args = callArgs(create, at);
  assert.match(args, /siteId: siteId/);
  assert.match(create, /final siteId = posture\.siteId;/);
  assert.match(args, /archiveContainerId: posture\.container\.archiveContainerId/);
  assert.match(args, /incognito: posture\.container\.incognito/);
});

// The model reads the binding before it builds the webview, to know whether
// the container's proxy has to be cleared first (PROXY-029). Read from another
// posture, it would clear, or fail to clear, a container the page never uses.
// The posture is the slot's running identity's, which is the host for a hosted
// tab (LIR-018).
test('the model reads the binding from the posture of the site webview config', () => {
  assert.match(model, /final posture = id\.sitePosture\(globalUserScripts: globalUserScripts\);/);
  assert.match(callArgs(model, model.indexOf('WebViewFactory.storeBinding(')), /^posture$/);
  const config = callArgs(model, model.indexOf('webview = WebViewFactory.createWebView('));
  assert.match(config, /posture: posture,/);
});

test('every URL bar offers site info', () => {
  for (const [rel, src] of [['lib/screens/webspace_page.dart', main], ['lib/screens/inappbrowser.dart', nested]]) {
    const calls = [...src.matchAll(/\bUrlBar\(/g)];
    assert.ok(calls.length > 0, `${rel} has no URL bar`);
    for (const m of calls) {
      assert.match(callArgs(src, m.index), /onSiteInfo:/, `a URL bar in ${rel} has no info button`);
    }
  }
});

test('site info is reached from the URL bar only, never a menu', () => {
  for (const [rel, src] of [['lib/screens/webspace_page.dart', main], ['lib/screens/inappbrowser.dart', nested]]) {
    assert.doesNotMatch(src, /value: "siteInfo"/, `${rel} offers site info in a menu`);
    assert.doesNotMatch(src, /case 'siteInfo':/, `${rel} handles a site info menu item`);
  }
});

test('the main sheet reads the inputs of the site webview posture', () => {
  // A hosted tab (LIR-018) binds its host's container, so both sides read
  // the slot's running identity rather than the owning site.
  assert.match(model, /final WebViewModel id = runningIdentity;/);
  const resolver = blockAfter(model, 'SitePosture sitePosture({', '}) {', 'web_view_model.dart');
  assert.match(resolver, /siteId: siteId,/);
  assert.match(resolver, /archiveContainerId: archiveContainerId,/);
  assert.match(resolver, /incognito: effectiveIncognito,/);
  const bar = callArgs(main, main.search(/\bUrlBar\(/));
  assert.match(bar, /final id = model\.runningIdentity;/);
  const rule = callArgs(bar, bar.indexOf('containerIdFor('));
  assert.match(rule, /siteId: id\.siteId/);
  assert.match(rule, /archiveContainerId: id\.archiveContainerId/);
  assert.match(rule, /incognito: id\.effectiveIncognito/);
});

test('the nested sheet reads the posture of the nested webview config', () => {
  const build = blockAfter(nested, '  Widget _createNestedInappWebView() {', null, 'inappbrowser.dart');
  assert.match(build, /final p = widget\.posture;/);
  assert.match(callArgs(build, build.indexOf('config: WebViewConfig(')), /posture: p,/);
  const show = blockAfter(nested, '  void _showSiteInfo() {', null, 'inappbrowser.dart');
  assert.match(show, /final p = widget\.posture;/);
  const rule = callArgs(show, show.indexOf('containerIdFor('));
  assert.match(rule, /siteId: p\.siteId/);
  assert.match(rule, /archiveContainerId: p\.container\.archiveContainerId/,
    'an archived site\'s nested screen binds its opaque container (ARCH-007)');
  assert.match(rule, /incognito: p\.container\.incognito/);
});
