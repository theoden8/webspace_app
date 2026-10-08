// Outbound routing funnel gate (LIR-014, LIR-015).
//
// A site with `routeOutboundLinks` on (an option of the in-app external-link
// mode) hands each cross-domain link it would nest or send to the system
// browser to the host first, which may open it as the site that claims it.
// A link the site's external-link mode blocks goes to the same hook, so the
// host can say it was blocked. The hook is a required field of
// WebViewHostHooks, which every site webview is built from, so no webview
// lacks it; what remains to check is that each launch in
// `WebViewModel.getWebView` asks it first. A launch that does not opens the
// link with the source's own posture instead.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const modelRel = 'lib/web_view_model.dart';
const mainRel = 'lib/screens/webspace_page.dart';
const linksRel = 'lib/controllers/link_controller.dart';
const model = read(modelRel);
const main = read(mainRel);
const links = read(linksRel);

const getWebView = blockAfter(model, '  Widget? getWebView(', '}) {', modelRel);

function previousLine(text, index) {
  const lines = text.slice(0, index).split('\n');
  lines.pop();
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  return lines.length ? lines[lines.length - 1] : '';
}

test('the tap and the redirect path carry out decisions in one place', () => {
  const calls = [...getWebView.matchAll(/\bdispatch\(\w+\.decision|\bdispatch\(decision,/g)];
  assert.equal(calls.length, 2,
    'shouldOverrideUrlLoading and onUrlChanged both go through dispatch');
});

test('every launch asks the outbound hook first', () => {
  assert.match(getWebView,
    /bool takenOver\(\) =>\s*hooks\.routeOutbound\(\s*this,\s*url: url,\s*decision: decision,\s*hadGesture: hadGesture\);/,
    'the hook is asked about the link being launched');
  const launches = [...getWebView.matchAll(
    /\b(hooks\.launchNested|hooks\.openInBrowser)\(/g)];
  assert.equal(launches.length, 2, 'one nested and one external launch');
  for (const m of launches) {
    const prev = previousLine(getWebView, m.index + m[0].length) + getWebView
      .slice(getWebView.lastIndexOf('\n', m.index), m.index);
    assert.match(prev, /if \(!takenOver\(\)\)/,
      `${m[1]} is not guarded by the outbound hook; a routed link would ` +
      'open with the source posture, or open twice');
  }
});

test('a blocked outbound link reaches the hook, and nothing launches', () => {
  const at = getWebView.indexOf('case NavigationDecision.blockOutbound:');
  assert.notEqual(at, -1, 'the blocked branch is gone');
  const branch = getWebView.slice(at, getWebView.indexOf('return', at));
  assert.match(branch, /takenOver\(\);/,
    'a blocked link must reach the host, which tells the user about a tap');
  assert.doesNotMatch(branch, /hooks\.launchNested|hooks\.openInBrowser/,
    'a blocked link must not open anywhere');
});

test("the link menu's Open routes as a tap would", () => {
  const open = blockAfter(links, '  Future<void> openLinkAsTapped(', ') async {', linksRel);
  const launches = [...open.matchAll(/await (_host\.launchNestedFor|launchUrlInSystemBrowser)\(/g)];
  assert.equal(launches.length, 2, 'expected a nested and an external launch');
  for (const m of launches) {
    const before = open.slice(0, m.index);
    const lastCase = before.lastIndexOf('case NavigationDecision.');
    assert.match(before.slice(lastCase), /routeOutbound\(/,
      `${m[1]} in openLinkAsTapped runs without asking outbound routing first`);
  }
});

test('routing hands every gate to the engine, with the live values', () => {
  const route = blockAfter(links, '  bool routeOutbound(', ') {', linksRel);
  assert.doesNotMatch(route, /ExperimentalFeature/,
    'link routing shipped: no developer-mode or experimental gate');
  assert.match(route, /LinkIntentDispatchEngine\.routeOutbound\(/,
    'the gates live in the engine, where they are unit-tested');
  for (const [arg, why] of [
    [/routeOutboundLinks: source\.effectiveRouteOutboundLinks/, 'the source opted in, in the in-app mode (LIR-013)'],
    [/kioskLocked: _host\.kioskLocked/, 'a locked kiosk reaches no other site (KIOSK-002)'],
    [/hadGesture: hadGesture/, 'only a user gesture is routed'],
    [/containersActive: _sites\.useContainers/, 'the legacy engine does not route'],
    [/outboundCandidates\(source\)/, 'candidates stay on the source side of the archive boundary'],
  ]) {
    assert.match(route, arg, `routeOutbound must be given ${why}`);
  }
});

test('a nested open runs through the engine, over the source only when routed', () => {
  const open = blockAfter(main, '  Future<void> _executeOpenNested(', '}) async {', mainRel);
  assert.match(open, /NestedOpenEngine\.run</,
    'the proxy sequence and the return to the source live in NestedOpenEngine');
  assert.match(open, /source: a\.sourceIsParent \? source : null/,
    'only a routed open skips the webspace switch and brings its source back');
  const host = blockAfter(main, 'class _NestedOpenHost implements NestedOpenHost<WebViewModel> {', null, mainRel);
  assert.match(host, /Future<void> activate\(int index\) => state\._setCurrentIndex\(index\);/,
    'the source must come back through the full activation, which applies its proxy first');
  assert.match(host, /Future<void> launchNested\([^)]*\)\s*=>\s*state\._launchNestedForModel\(/,
    'the screen opens through the NESTED-010 funnel');
});

// Which site-set changes prune (LIR-017) is SiteSetChange.effects, tested in
// test/site_runtime_test.dart; where the commit prunes is
// test/js/site_set_commit.test.js. An import prunes earlier, in its plan.
test('an import prunes inside its plan (LIR-017, BACKUP-013)', () => {
  const importRel = 'lib/services/settings_import_engine.dart';
  const plan = blockAfter(
    read(importRel),
    'SettingsImportPlan planSettingsImport(', '}) {', importRel);
  assert.match(plan, /OutboundPreferenceGc\.pruneAll/,
    'an import must prune inside the plan (BACKUP-013)');
});
