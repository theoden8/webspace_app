// Outbound routing funnel gate (LIR-014, LIR-015).
//
// A site with `routeOutboundLinks` on hands each cross-domain link it would
// nest or send to the system browser to the host first, which may open it as
// the site that claims it. The hook is one line in front of each launch in
// `WebViewModel.getWebView`, and the host only sees it on the webviews it
// passed it to. A launch added without the line, or a webview built without
// the hook (`getController` builds one when the frame has not yet), silently
// opens the link with the source's own posture instead.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const modelRel = 'lib/web_view_model.dart';
const mainRel = 'lib/main.dart';
const model = fs.readFileSync(path.join(repoRoot, modelRel), 'utf8');
const main = fs.readFileSync(path.join(repoRoot, mainRel), 'utf8');

const getWebView = blockAfter(model, '  Widget getWebView(', '}) {', modelRel);
const getController = blockAfter(
  model, '  WebViewController? getController(', '}) {', modelRel);

function previousLine(text, index) {
  const lines = text.slice(0, index).split('\n');
  lines.pop();
  while (lines.length && lines[lines.length - 1].trim() === '') lines.pop();
  return lines.length ? lines[lines.length - 1] : '';
}

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

test('every launch in getWebView asks the outbound hook first', () => {
  const launches = [...getWebView.matchAll(
    /\b(launchUrlFunc|launchUrlInSystemBrowser)\(([^,)]+)/g)];
  assert.ok(launches.length >= 4,
    'getWebView should launch nested and external on both navigation paths');
  for (const m of launches) {
    const prev = previousLine(getWebView, m.index);
    assert.match(prev, /onOutboundLink\?\.call\(/,
      `${m[1]}(${m[2]}...) is not guarded by onOutboundLink; a routed link ` +
      'would open with the source posture');
    assert.ok(prev.includes(m[2].trim()),
      `the hook before ${m[1]}(${m[2]}...) is asked about a different URL`);
    assert.match(prev, /\?\? false\) return/,
      'a link the hook took over must not also be launched');
  }
});

test('getController forwards the hook to the webview it builds', () => {
  assert.match(getController, /getWebView\([^;]*onOutboundLink: onOutboundLink/s,
    'a webview built by getController would never route');
});

test('every site webview main.dart builds carries the hook', () => {
  const calls = [...main.matchAll(/\.(getWebView|getController)\(\s*launchUrl\b/g)];
  assert.ok(calls.length > 0, 'expected site webview builds in main.dart');
  for (const m of calls) {
    const call = callText(main, m.index);
    assert.match(call, /onOutboundLink:\s*_outboundLinkHookFor\(/,
      `${m[1]} at offset ${m.index} builds a webview without the outbound hook`);
  }
});

test('routing hands every gate to the engine, with the live values', () => {
  const route = blockAfter(main, '  bool _routeOutboundLink(', ') {', mainRel);
  assert.doesNotMatch(route, /ExperimentalFeature/,
    'link routing shipped: no developer-mode or experimental gate');
  assert.match(route, /LinkIntentDispatchEngine\.routeOutbound\(/,
    'the gates live in the engine, where they are unit-tested');
  for (const [arg, why] of [
    [/routeOutboundLinks: source\.routeOutboundLinks/, 'the source opted in (LIR-013)'],
    [/kioskLocked: _kioskLocked/, 'a locked kiosk reaches no other site (KIOSK-002)'],
    [/hadGesture: hadGesture/, 'only a user gesture is routed'],
    [/containersActive: _useContainers/, 'the legacy engine does not route'],
    [/_outboundCandidates\(source\)/, 'candidates stay on the source side of the archive boundary'],
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

test('every point that can orphan a preference prunes it (LIR-017)', () => {
  const prunes = (body) => /_pruneOutboundPreferences\(\)/.test(body);
  const load = blockAfter(main, '  Future<void> _loadWebViewModels() async {', null, mainRel);
  assert.ok(prunes(load), 'startup must prune');
  const del = blockAfter(main, '  Future<void> _deleteSite(', ') async {', mainRel);
  const pruneAt = del.indexOf('_pruneOutboundPreferences()');
  assert.ok(pruneAt !== -1 && pruneAt < del.indexOf('await _saveWebViewModels()'),
    'a delete must prune before it saves');
  const toArchive = blockAfter(main, '  Future<void> _moveSiteToArchive(', ') async {', mainRel);
  const at = toArchive.indexOf('_pruneOutboundPreferences()');
  assert.ok(at !== -1 && at < toArchive.indexOf('target.state.sites.add(model.toJson())'),
    'a move into an archive must prune before the archived copy is taken');
  const outOf = blockAfter(main, '  Future<void> _moveSiteOutOfArchive(', ') async {', mainRel);
  const flip = outOf.indexOf('model.isArchiveTier = false;');
  const after = outOf.indexOf('_pruneOutboundPreferences()');
  assert.ok(flip !== -1 && after > flip,
    'a move out of an archive must prune after the tier flip');
  const importRel = 'lib/services/settings_import_engine.dart';
  const plan = blockAfter(
    fs.readFileSync(path.join(repoRoot, importRel), 'utf8'),
    'SettingsImportPlan planSettingsImport(', '}) {', importRel);
  assert.match(plan, /OutboundPreferenceGc\.pruneAll/,
    'an import must prune inside the plan (BACKUP-013)');
});
