// Go-home commit funnel gate (NAV-010).
//
// `activate(null)` is what "back to webspaces" and every other return
// to the site list run through. Its teardown of the site being left is a chain
// of native round-trips, and each of them can throw, be superseded by a newer
// activation, or — on an iOS page whose JS thread an earlier pause froze —
// never answer at all. While `_currentIndex = index` sat *after* that chain,
// any of those outcomes returned early with the user still on the site: the
// tap did nothing, with no error and nothing in the UI to retry against.
//
// So the home state is committed before the teardown, and the teardown itself
// is funnelled through `_teardown` (bounded + non-fatal, see
// `SiteTeardownEngine`). A future edit that reintroduces an await ahead of the
// commit, or dispatches a pause straight from a step, re-opens it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const rel = 'lib/controllers/site_activation_controller.dart';
const src = read(rel);
const tableRel = 'lib/controllers/activation_table.dart';
const tableSource = read(tableRel);

const activate = blockAfter(
  src, 'Future<void> activate(WebViewModel? site) async {', null, rel);
// The steps an activation and a return home run.
const table = blockAfter(
  tableSource, 'static final activationFlow =', 'switch (place) {', tableRel);
// Comments stripped: prose naming an await would decide the ordering check.
const goHome = blockAfter(
  activate,
  'if (site == null) {',
  null,
  rel).replace(/\/\/.*$/gm, '');
// The go-home input's own step, the first the flow runs.
const goHomeStep = (() => {
  const at = table.indexOf('ActivationPlace.goHome => Step.input(');
  assert.notEqual(at, -1, `${tableRel} no longer runs going home as an input step`);
  // Up to the next case label; the step's own `to(ActivationPlace.x)` is
  // indented deeper.
  return table.slice(at, table.indexOf('\n      ActivationPlace.', at + 1));
})();
const run = '_runFlow(flow, from: ActivationPlace.goHome)';

test('going home commits the screen synchronously', () => {
  const at = tableSource.indexOf('static final _homeOff = ');
  assert.notEqual(at, -1, `${tableRel} no longer defines _homeOff`);
  const homeOff = tableSource.slice(at, tableSource.indexOf(';', at));
  assert.match(homeOff, /_current\.becomes\(_noSite\)/,
    '_homeOff must commit the screen home');
  assert.ok(!/call:/.test(goHomeStep),
    'the goHome step waits on nothing: its effects run before any await');
  assert.equal((goHomeStep.match(/_homeOff\b/g) || []).length, 2,
    'both arms of the goHome step must commit the screen home');
});

test('the go-home branch commits the screen before it awaits anything', () => {
  const commit = goHome.indexOf(run);
  assert.notEqual(commit, -1, `go-home must run the table from goHome: ${run}`);
  const firstAwait = goHome.indexOf('await ');
  assert.ok(firstAwait === -1 || firstAwait + 'await '.length === commit,
    'an await ahead of the goHome step can abandon the branch with the site ' +
    'the user asked to leave still on screen');
});

test('the go-home branch cannot return before the commit', () => {
  const before = goHome.slice(0, goHome.indexOf(run));
  assert.ok(!/\breturn\b/.test(before),
    'nothing may bail out of go-home before the home state is committed');
});

test('outgoing-site teardown is funnelled through _teardown', () => {
  for (const raw of [
    /\.pauseWebView\b/,
    /\.pauseMediaPlayback\b/,
    /\.stopRealCapture\b/,
  ]) {
    assert.ok(!raw.test(activate + table),
      `a step dispatches ${raw} directly; route it through ` +
      '_teardown so the sequence stays bounded and non-fatal');
  }
  // A step pauses through its port; the port's pause is the funnel.
  assert.match(src, /pause: \(site, \{required version\}\) =>\s*_teardown\(site, version: version, steps: _pauseSteps\(site\)\)/,
    'a step\'s pause must run the teardown funnel');
  assert.match(table, /final outgoing = _outgoingSite\(c\);[\s\S]*?c\.api\.pause\(outgoing, /,
    'the activation must quiesce the site being left');
  // The site being left is the home flow's own field, set as it starts.
  assert.match(table, /ActivationPlace\.hQuiesce => Step\([\s\S]*?c\.api\.pause\(_site\.of\(c\), /,
    'going home must quiesce the site being left');
  assert.match(table, /_site\.becomes\(_onScreen\)/,
    'the home flow must carry the site it leaves from its input step');
});

test('the funnel delegates to the bounded engine', () => {
  const funnel = blockAfter(src, 'Future<void> _teardown(', ') async {', rel);
  assert.match(funnel, /SiteTeardownEngine\.quiesceOutgoing\(/,
    '_teardown must run the steps through SiteTeardownEngine');
  assert.match(funnel, /superseded: \(\) => version != _sites\.activationVersion/,
    'the teardown must still bail out for a newer activation (PAUSE-005)');
});
