// Go-home commit funnel gate (NAV-010).
//
// `_setCurrentIndex(null)` is what "back to webspaces" and every other return
// to the site list run through. Its teardown of the site being left is a chain
// of native round-trips, and each of them can throw, be superseded by a newer
// activation, or — on an iOS page whose JS thread an earlier pause froze —
// never answer at all. While `_currentIndex = index` sat *after* that chain,
// any of those outcomes returned early with the user still on the site: the
// tap did nothing, with no error and nothing in the UI to retry against.
//
// So the home state is committed before the teardown, and the teardown itself
// is funnelled through `_quiesceOutgoingSite` (bounded + non-fatal, see
// `SiteTeardownEngine`). A future edit that reintroduces an await ahead of the
// commit, or dispatches a pause straight from `_setCurrentIndex`, re-opens it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/main.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const setCurrentIndex = blockAfter(
  src, 'Future<void> _setCurrentIndex(int? index) async {', null, rel);
const goHome = blockAfter(
  setCurrentIndex,
  'if (index == null || index < 0 || index >= _webViewModels.length) {',
  null,
  rel);

test('the go-home branch commits _currentIndex before it awaits anything', () => {
  const commit = goHome.indexOf('_currentIndex = index;');
  assert.notEqual(commit, -1, 'go-home must assign _currentIndex = index');
  const firstAwait = goHome.indexOf('await ');
  if (firstAwait !== -1) {
    assert.ok(commit < firstAwait,
      'an await ahead of the commit can abandon the branch with _currentIndex ' +
      'still on the site the user asked to leave');
  }
});

test('the go-home branch cannot return before the commit', () => {
  const commit = goHome.indexOf('_currentIndex = index;');
  const before = goHome.slice(0, commit);
  assert.ok(!/\breturn\b/.test(before),
    'nothing may bail out of go-home before the home state is committed');
});

test('outgoing-site teardown is funnelled through _quiesceOutgoingSite', () => {
  for (const raw of [
    /\.pauseWebView\(\)/,
    /\.pauseMediaPlayback\(\)/,
    /\.stopRealCameraCapture\(\)/,
  ]) {
    assert.ok(!raw.test(setCurrentIndex),
      `_setCurrentIndex dispatches ${raw} directly; route it through ` +
      '_quiesceOutgoingSite so the sequence stays bounded and non-fatal');
  }
  assert.match(setCurrentIndex, /_quiesceOutgoingSite\(/,
    '_setCurrentIndex must quiesce the site being left');
});

test('the funnel delegates to the bounded engine', () => {
  const funnel = blockAfter(src, 'Future<void> _quiesceOutgoingSite(', ') async {', rel);
  assert.match(funnel, /SiteTeardownEngine\.quiesceOutgoing\(/,
    '_quiesceOutgoingSite must run the steps through SiteTeardownEngine');
  assert.match(funnel, /superseded: \(\) => version != _setCurrentIndexVersion/,
    'the teardown must still bail out for a newer activation (PAUSE-005)');
});
