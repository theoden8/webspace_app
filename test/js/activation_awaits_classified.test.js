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
// every await in `setCurrentIndex` is listed here with the reason it cannot
// hang, and a new one fails until it is. A Tor call is refused outright. It
// is a round trip to a control socket that can die under the app, and the
// engine already holds Tor sites until a pin lands, so nothing on the
// activation path needs to wait for it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const mainRel = 'lib/screens/webspace_page.dart';
const main = read(mainRel);
const actRel = 'lib/controllers/site_activation_controller.dart';
const act = read(actRel);
const engineRel = 'lib/services/tor_engine.dart';
const engine = read(engineRel);

const setCurrentIndex = blockAfter(
  act, 'Future<void> setCurrentIndex(int? index) async {', null, actRel);

// Callee of each await, with an index expression reduced to `[]`.
const CLASSIFIED = {
  '_quiesceOutgoingSite':
    'Bounded and non-fatal: SiteTeardownEngine runs it under a budget (NAV-010).',
  '_navStates.loadState':
    'A secure-storage read on the device. No socket, nothing to reclaim.',
  'applyResidency':
    'Each unload is a WebKit/WebView saveState on the main thread, then a '
    + 'dispose, under the legacy engine after a cookie capture from the '
    + 'in-process cookie store; each cache clear is an in-process WebView call.',
  '_host.refreshRoutes':
    'Android router mode: rewrites the in-process relay\'s route table.',
  '_containers.ensureContainer':
    'An in-process container lookup, caught and logged on failure.',
  '_restoreCookiesForSite':
    'Legacy engine only: writes cookies into the in-process cookie store.',
  'ensureSiteHtml':
    'Decrypts a cached page from disk in Dart.',
  '_sites.models[].resumeWebView':
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
    'a new await in setCurrentIndex: if it can go unanswered (a socket, a '
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
    'setCurrentIndex awaits TorService; the engine holds Tor sites until a '
    + 'pin lands, so call syncTorExitPin instead');
  assert.match(setCurrentIndex, /_host\.syncTorExitPin\(/,
    'setCurrentIndex must still put the pin the loaded sites want in force');
  const network = read('lib/controllers/site_network_controller.dart');
  for (const [rel, src] of [[mainRel, main], [actRel, act], ['lib/controllers/site_network_controller.dart', network]]) {
    assert.ok(!/await\s+TorService\.instance\.setExitCountry/.test(src),
      `${rel} awaits setExitCountry; route it through syncTorExitPin`);
  }
  const sync = blockAfter(network, 'void syncTorExitPin(', ') {', 'lib/controllers/site_network_controller.dart');
  assert.match(sync, /unawaited\(TorService\.instance\.setExitCountry\(/,
    'syncTorExitPin must not wait on the change it starts');
});

test('the pin follows a memory-pressure eviction', () => {
  const pressure = blockAfter(main, 'Future<void> _handleMemoryPressure() async {',
    null, mainRel);
  const unload = pressure.search(/await _activation\.applyResidency\(plan,/);
  assert.notEqual(unload, -1, 'memory pressure must still evict through the plan');
  assert.ok(pressure.indexOf('_network.syncTorExitPin(', unload) > unload,
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
