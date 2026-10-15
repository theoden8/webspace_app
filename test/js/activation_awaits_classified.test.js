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
// every platform call a flow's step may wait on (`ActivationStep.calls`, which
// the walks hold the engines to) is listed here with the reason it cannot
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
const tableRel = 'lib/controllers/activation_table.dart';
const tableSource = read(tableRel);
const stepsRel = 'lib/services/activation_step.dart';
const stepsSource = read(stepsRel);
const steps = blockAfter(stepsSource, 'enum ActivationStep {', null, stepsRel);
// `member('Interface.method')`: the label of each PlatformCall.
const LABELS = new Map(
  [...blockAfter(stepsSource, 'enum PlatformCall {', null, stepsRel)
    .matchAll(/^\s+(\w+)\('([^']+)'\)/gm)].map((m) => [m[1], m[2]]));
const engineRel = 'lib/services/tor_engine.dart';
const engine = read(engineRel);

// What the input's own step does before the table runs, and the table.
const activate = blockAfter(
  act, 'Future<void> activate(WebViewModel? site) async {', null, actRel);
const table = blockAfter(
  tableSource, 'static final activationFlow =', 'switch (place) {', tableRel);

// Every platform call a step declares, `Interface.method`.
const CLASSIFIED = {
  'WebViewStateStorage.loadState':
    'A secure-storage read on the device. No socket, nothing to reclaim.',
  'WebViewStateStorage.saveState':
    'A secure-storage write on the device.',
  'WebViewStateStorage.removeState':
    'A secure-storage delete on the device.',
  'WebViewController.saveState':
    'A WebKit/WebView saveState on the main thread.',
  'WebViewController.clearCache':
    'An in-process WebView call.',
  'WebViewController.evaluateJavascript':
    'Bounded and non-fatal: SiteTeardownEngine runs it under a budget '
    + '(NAV-010), so a frozen page cannot hold the switch.',
  'WebViewController.pause':
    'Bounded and non-fatal, as above.',
  'WebViewController.resume':
    'A main-thread WebView resume, caught on a disposed controller.',
  'CookieManager.getAllCookies':
    'Legacy engine only: reads the in-process cookie store.',
  'CookieManager.setCookie':
    'Legacy engine only: writes the in-process cookie store.',
  'CookieManager.deleteAllCookies':
    'Legacy engine only: empties the in-process cookie store.',
  'CookieSecureStorage.saveCookiesForSite':
    'A secure-storage write on the device.',
  'CookieSecureStorage.loadCookiesForSite':
    'A secure-storage read on the device.',
  'ContainerNative.getOrCreateContainer':
    'An in-process container lookup, caught and logged on failure.',
  'ProxyRouter.refreshRoutes':
    'The in-process relay swaps its route table: a map decoded and replaced, '
    + 'no socket or channel.',
  'ProxyController.setProxyOverride':
    'A nested open or a wake\'s check: the WebView ProxyController applies '
    + 'the rule and calls back on its executor, and the relay it may start '
    + 'binds a loopback port; neither waits on the network. A wake\'s Tor '
    + 'pin beside it waits at most its deadline.',
  'Navigator.push':
    'A nested open only: it waits for the user to pop the screen, and only '
    + 'another nested open waits behind it, which the screen covers.',
  'HeadlessInAppWebView.run':
    'A wake\'s check only, off the activation path: the webview\'s creation '
    + 'waits at most its timeout (HeadlessSiteChecks), and the load is issued, '
    + 'not awaited.',
  'HeadlessInAppWebView.dispose':
    'A wake\'s check only: an in-process dispose of a webview the wake made.',
  'BackgroundWake.settle':
    'A wake only: the reloads\' settle waits at most its deadline '
    + '(BackgroundWakeEngine.settleDeadline) and the post grace after it.',
  'DnsBlockService.fetchLevel':
    'A DNS download only, which no activation waits on: each mirror is '
    + 'bounded by fetchViaAppProxy\'s timeout.',
  'ConnectivityService.isOnline':
    'A webspace switch only, which a newer input supersedes: the lookup is '
    + 'bounded by hostCanResolve\'s three-second timeout, all a drawer tap '
    + 'behind the switch waits.',
  'WebViewStateStorage.removeStatesForSite':
    'An archive close only: a secure-storage delete on the device.',
  'ContainerNative.deleteContainer':
    'A container\'s data deleted on the device; one a mounted webview still '
    + 'binds is refused, not waited on (LIR-023).',
  'Archive.save':
    'An archive close only: the sealed state written to its slot file.',
  'Archive.close':
    'An archive close only: the slot written again and the key zeroed in '
    + 'memory.',
  'PageHost.commitSites':
    'An archive close only: the page\'s commit of the archive\'s sites '
    + 'leaving, list changes and device saves; its Tor holders only shrink, '
    + 'so it starts nothing, and the exit pin is set without waiting '
    + '(BUG-018).',
  'SchedulerBinding.endOfFrame':
    'An archive close only, which the user starts from the page in front: '
    + 'the next frame. In the background no frame is drawn and the close '
    + 'waits for the app to return, which it must, since the webviews stay '
    + 'mounted until then; only another archive operation waits behind it.',
};

function declaredCalls(body) {
  const out = new Set();
  for (const m of body.matchAll(/calls:\s*\{([^}]*)\}/g)) {
    for (const call of m[1].matchAll(/PlatformCall\.(\w+)/g)) {
      const label = LABELS.get(call[1]);
      assert.ok(label, `${call[1]} is no PlatformCall`);
      out.add(label);
    }
  }
  return out;
}

function awaitedCallees(body) {
  const out = [];
  const re = /await\s+([A-Za-z_][\w.!?]*(?:\[[^\]]*\][\w.!?]*)*)\s*\(/g;
  let m;
  while ((m = re.exec(body)) !== null) {
    out.push(m[1].replace(/\[[^\]]*\]/g, '[]').replace(/[!?]/g, ''));
  }
  return out;
}

test('every platform call a step may wait on is classified', () => {
  const unclassified = [...declaredCalls(steps)]
    .filter((call) => !(call in CLASSIFIED));
  assert.deepEqual(unclassified, [],
    'a new platform call on a step: if it can go unanswered (a socket, a '
    + 'frozen page, another process), bound it or take it off the path; '
    + 'otherwise add it to CLASSIFIED with the reason it cannot');
});

test('every classified call is still declared by a step', () => {
  // A stale entry reads as a decision about code that no longer exists.
  const present = declaredCalls(steps);
  const stale = Object.keys(CLASSIFIED).filter((c) => !present.has(c));
  assert.deepEqual(stale, [], 'drop the entry for a call that is gone');
});

test('the input waits on nothing but its flow', () => {
  // Every await of an activation is a step of the table, whose calls the
  // walks hold to the steps above; the input itself only runs the flow.
  assert.deepEqual(
    awaitedCallees(activate).filter((c) => !['_runToExit', '_runFlow'].includes(c)),
    [],
    'an await in activate outside the table is a wait no step declares');
});

test('the activation path never waits on Tor', () => {
  assert.ok(!/await\s+TorService\b/.test(activate + table),
    'the activation awaits TorService; the engine holds Tor sites until a '
    + 'pin lands, so call syncTorExitPin instead');
  assert.ok(![...declaredCalls(steps)].some((c) => /^Tor/.test(c)),
    'a step waits on Tor; the engine holds Tor sites until a pin lands');
  assert.match(table, /_torPin\b/,
    'the activation must still put the pin the loaded sites want in force');
  assert.match(tableSource, /static final _torPin = Note<ActivationFlow>\(\s*\(c\) => ActivationFlow\.page\.from\(c\)\.syncTorExitPin\(/,
    '_torPin must put the pin in force through syncTorExitPin');
  const flowRel = 'lib/controllers/activation_flow.dart';
  assert.match(blockAfter(read(flowRel), 'void syncTorExitPin(', null, flowRel),
    /_r\.host\.syncTorExitPin\(/, "the page port's pin is the host's");
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
  const pressure = blockAfter(act, 'Future<void> memoryPressure() async {',
    null, actRel);
  const unload = pressure.search(/await _runFlow\(/);
  assert.notEqual(unload, -1, 'memory pressure must still evict through the flow');
  assert.ok(pressure.indexOf('_host.syncTorExitPin(', unload) > unload,
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
