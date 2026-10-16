// TOR-014: no path puts an exit pin in force while a site that disagrees
// with it is still loaded.
//
// tor has one ExitNodes, so the pin in force is the pin of every loaded Tor
// site. Activating a site unloads the siblings that disagree before the pin
// changes. Saving a site's settings did not: moving one site to Canada while
// a Denmark site was loaded changed the pin to {ca}, and the Denmark site was
// rebuilt under it as soon as Tor came back up, leaving from Canada.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, blockAfter } = require('./helpers/source');

const rel = 'lib/controllers/activation_table.dart';
const src = read(rel);
const engineRel = 'lib/services/site_unload_engine.dart';
const plan = blockAfter(read(engineRel), 'static ResidencyPlan plan(', undefined, engineRel);

/** The plan's branch for [event], up to the next case. */
function planCase(event) {
  const at = plan.indexOf(`case ${event}(`);
  assert.notEqual(at, -1, `${engineRel} plans no ${event}`);
  const next = plan.indexOf('\n      case ', at + 1);
  return plan.slice(at, next === -1 ? undefined : next);
}

/** [calls] names how [fn] plans, applies and pins: activation and the network
 * controller reach the same three through different receivers. */
function unloadsBeforePin(fn, label, event, calls) {
  const pin = fn.indexOf(calls.pin);
  assert.notEqual(pin, -1, `${label} no longer puts the pin in force`);
  // The plan may switch on the flow's kind between the call and the event.
  const planned = fn.search(new RegExp(
    `${calls.plan.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}[^;]{0,200}?${event}\\(`));
  assert.notEqual(planned, -1,
    `${label} changes the pin without asking which loaded sites disagree with it`);
  const applied = fn.indexOf(calls.apply);
  assert.ok(applied !== -1 && applied < pin && planned < pin,
    `${label} does not unload the disagreeing sites before the pin changes`);
  assert.match(planCase(event), /torDissenters\(/,
    `the ${event} plan must unload the Tor sites that disagree with the pin`);
}

test('the plan asks Tor which sites disagree with the pin', () => {
  assert.match(plan, /Set<int> torDissenters\([^)]*\) => host\.torAvailable\s*\?\s*indicesToUnloadForTorExitMismatch\(/);
});

test('activating a site unloads the siblings its pin disagrees with first', () => {
  // The plan is made at the plan step, the unload table nested after it,
  // and the pin put in force at the applied step once the plan is spent.
  const from = src.indexOf('static ResidencyPlan _planOf(');
  assert.notEqual(from, -1, `${rel} no longer plans at the plan step`);
  unloadsBeforePin(src.slice(from), 'the activation', 'Activating',
    { plan: 'residencyPlan(', apply: 'Within(_inUnload)', pin: 'then: [_torPin]' });
  assert.match(src, /static final _torPin = Note<ActivationFlow>\(\s*\(c\) => ActivationFlow\.page\.from\(c\)\.syncTorExitPin\(/,
    '_torPin must put the pin in force through syncTorExitPin');
  const flow = 'lib/controllers/activation_flow.dart';
  assert.match(blockAfter(read(flow), 'void syncTorExitPin(', undefined, flow),
    /_r\.host\.syncTorExitPin\(/, "the page port's pin is the host's");
});

test('saving settings unloads the sites the new pin disagrees with first', () => {
  const net = 'lib/controllers/site_network_controller.dart';
  unloadsBeforePin(blockAfter(read(net), 'Future<void> syncTorHolders()', undefined, net),
    'syncTorHolders', 'TorExitSettled',
    { plan: 'SiteUnloadEngine.plan(residency, event: ', apply: 'SiteUnloadEngine.apply(', pin: 'syncTorExitPin(' });
});
