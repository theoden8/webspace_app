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

test('routing is gated on the gesture, the container engine and the boundary', () => {
  const route = blockAfter(main, '  bool _routeOutboundLink(', ') {', mainRel);
  assert.match(route, /if \(!source\.routeOutboundLinks/,
    'routing must stay off unless the source opted in (LIR-013)');
  assert.match(route, /_kioskLocked/,
    'a locked kiosk shell must not reach another site through routing (KIOSK-002)');
  assert.match(route, /hadGesture: hadGesture/);
  assert.match(route, /containersActive: _useContainers/);
  assert.match(route, /_outboundCandidates\(source\)/,
    'candidates must come from the source side of the archive boundary');
});

test('a routed open stays in the webspace and hands the source back', () => {
  const open = blockAfter(main, '  Future<void> _executeOpenNested(', '}) async {', mainRel);
  const guard = open.indexOf('if (!a.sourceIsParent)');
  const switchAll = open.indexOf('_maybeSwitchToAllForSite(');
  assert.ok(guard !== -1 && guard < switchAll,
    'a routed open must not switch webspace (LIR-015)');
  const launch = open.indexOf('await _launchNestedForModel(model, a.url);');
  assert.notEqual(launch, -1);
  assert.match(open.slice(launch), /^await _launchNestedForModel\(model, a\.url\);\s*await returnToSource\(\);/,
    'the source must be re-activated under its own proxy after the pop');
});
