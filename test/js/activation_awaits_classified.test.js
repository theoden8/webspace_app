// Activation-path await gate (BUG-018, NAV-010).
//
// A site switch that awaits something which never answers does nothing: no
// error, no spinner, just a tap that is ignored, and every later tap queues
// behind a newer version that waits on the same thing. It has happened twice.
// The go-home teardown waited on a page an earlier pause had frozen (#551,
// NAV-010), and the Tor exit-country change waited on a control socket iOS
// reclaimed while the app slept (BUG-018).
//
// So this gate does not decide which awaits are safe. It makes someone decide:
// every await in `_setCurrentIndex` is listed here with the reason it cannot
// hang, and a new one fails until it is. A Tor call is refused outright. It
// is a round trip to a control socket that can die under the app, and the
// engine already holds Tor sites until a pin lands, so nothing on the
// activation path needs to wait for it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const mainRel = 'lib/main.dart';
const main = fs.readFileSync(path.join(repoRoot, mainRel), 'utf8');
const engineRel = 'lib/services/tor_engine.dart';
const engine = fs.readFileSync(path.join(repoRoot, engineRel), 'utf8');

const setCurrentIndex = blockAfter(
  main, 'Future<void> _setCurrentIndex(int? index) async {', null, mainRel);

// Callee of each await, with an index expression reduced to `[]`.
const CLASSIFIED = {
  '_quiesceOutgoingSite':
    'Bounded and non-fatal: SiteTeardownEngine runs it under a budget (NAV-010).',
  '_stateStorage.loadState':
    'A secure-storage read on the device. No socket, nothing to reclaim.',
  '_unloadSiteForDomainSwitch':
    'Legacy engine only: cookie capture from the in-process cookie store.',
  '_unloadSiteForOtherReason':
    'A WebKit/WebView saveState on the main thread, then a dispose.',
  '_refreshProxyRoutes':
    'Android router mode: rewrites the in-process relay\'s route table.',
  '_webViewModels[].clearWebViewCache':
    'An in-process WebView cache clear.',
  '_containerIsolation.ensureContainer':
    'An in-process container lookup, caught and logged on failure.',
  '_restoreCookiesForSite':
    'Legacy engine only: writes cookies into the in-process cookie store.',
  '_ensureSiteHtml':
    'Decrypts a cached page from disk in Dart.',
  '_webViewModels[].resumeWebView':
    'A main-thread WebView resume, caught on a disposed controller.',
};

function awaitedCallees(body) {
  const out = [];
  const re = /await\s+([A-Za-z_][\w.!?]*(?:\[[^\]]*\][\w.!?]*)*)\s*\(/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    out.push(m[1].replace(/\[[^\]]*\]/g, '[]').replace(/[!?]/g, ''));
  }
  return out;
}

test('every await on the activation path is classified', () => {
  const unclassified = awaitedCallees(setCurrentIndex)
    .filter((callee) => !(callee in CLASSIFIED));
  assert.deepEqual(unclassified, [],
    'a new await in _setCurrentIndex: if it can go unanswered (a socket, a '
    + 'frozen page, another process), bound it or take it off the path; '
    + 'otherwise add it to CLASSIFIED with the reason it cannot');
});

test('every classified await is still there', () => {
  // A stale entry reads as a decision about code that no longer exists.
  const present = new Set(awaitedCallees(setCurrentIndex));
  const stale = Object.keys(CLASSIFIED).filter((c) => !present.has(c));
  assert.deepEqual(stale, [], 'drop the entry for an await that is gone');
});

test('the activation path never waits on Tor', () => {
  assert.ok(!/await\s+TorService\b/.test(setCurrentIndex),
    '_setCurrentIndex awaits TorService; the engine holds Tor sites until a '
    + 'pin lands, so call _syncTorExitPin instead');
  assert.match(setCurrentIndex, /_syncTorExitPin\(/,
    '_setCurrentIndex must still put the pin the loaded sites want in force');
  assert.ok(!/await\s+TorService\.instance\.setExitCountry/.test(main),
    `${mainRel} awaits setExitCountry; route it through _syncTorExitPin`);
  const sync = blockAfter(main, 'void _syncTorExitPin(', ') {', mainRel);
  assert.match(sync, /unawaited\(TorService\.instance\.setExitCountry\(/,
    '_syncTorExitPin must not wait on the change it starts');
});

test('the pin follows a memory-pressure eviction', () => {
  const pressure = blockAfter(main, 'Future<void> _handleMemoryPressure() async {',
    null, mainRel);
  const unload = pressure.indexOf('await _unloadSiteForOtherReason(victim);');
  assert.notEqual(unload, -1, 'memory pressure must still evict through the helper');
  assert.ok(pressure.indexOf('_syncTorExitPin(', unload) > unload,
    'the pin of an evicted site must be recomputed when it goes, not at the '
    + 'next activation');
});

test('the engine bounds the round trip it makes', () => {
  const calls = engine.split('_runtime\n').join('_runtime')
    .match(/_runtime\s*\.applyExitCountry\([^;]*;/g) || [];
  assert.ok(calls.length > 0, `${engineRel} must still apply the pin`);
  for (const call of calls) {
    assert.match(call, /\.timeout\(kTorExitPinApplyTimeout\)/,
      `${engineRel} awaits applyExitCountry without a deadline: ${call}`);
  }
});
