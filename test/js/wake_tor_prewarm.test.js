// TOR-006: a notification site routed through Tor is checked by a wake, not
// skipped because Tor was still coming up, and Tor stays up through the
// background grace window.
//
// The decision is Dart's and is tested there (test/wake_candidates_test.dart
// for `wakeWaitsForTor`, test/background_wake_engine_test.dart for the budget
// a wait spends). What no Dart test reaches is the controller's order, which
// needs the app's host and Tor's platform runtime: revive Tor, wait for it
// when a Tor site would be checked, then plan, inside the OS task's budget.
// And the grace window holds because nothing on the way to the background
// lets go of Tor: its holders follow the site list alone, so an app that
// pauses keeps every Tor site's holder and the idle stop never starts.
// Rung 5: no type orders a method's awaits.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, code } = require('./helpers/source');
const { blockAfter } = require('./helpers/dart_blocks');

const controller = code(read('lib/controllers/background_sites_controller.dart'));

test('TOR-006: the wake waits for Tor after reviving it and before it plans', () => {
  const wake = blockAfter(controller, 'Future<void> wake() async');
  const at = (marker) => {
    const i = wake.indexOf(marker);
    assert.ok(i >= 0, `wake() no longer contains ${marker}`);
    return i;
  };
  const began = at('final began = _wakeHost.now();');
  const revive = at('TorService.instance.revive()');
  const asks = at('wakeWaitsForTor(_sites.models');
  const waits = at('_torUpWithin(_torWakeDeadline)');
  const plans = at('_wakeEngine.wake(_wakeHost, since: began)');
  assert.ok(began < revive && revive < asks && asks < waits && waits < plans,
    'the task\'s clock starts first, Tor is revived, waited for, then the wake plans');
});

test('TOR-006: the wait is shorter than the shortest task budget', () => {
  const engine = code(read('lib/services/background_wake_engine.dart'));
  const budgets = [...engine.matchAll(/^\s+\w+\(Duration\(seconds: (\d+)\)\)[,;]/gm)]
    .map((m) => Number(m[1]));
  const wait = Number(/_torWakeDeadline = Duration\(seconds: (\d+)\)/.exec(controller)[1]);
  assert.ok(budgets.length >= 2, 'the WakeTask budgets moved');
  assert.ok(wait < Math.min(...budgets) / 2,
    'a wait past half the budget leaves the loads no time to settle');
});

test('TOR-006: Tor\'s holders follow the site list, not the lifecycle', () => {
  const network = code(read('lib/controllers/site_network_controller.dart'));
  const sync = blockAfter(network, 'Future<void> syncTorHolders() async');
  assert.match(sync, /for \(final m in _sites\.models\)/,
    'every Tor site holds Tor, loaded or not');
  for (const rel of [
    'lib/controllers/app_lifecycle_controller.dart',
    'lib/services/background_task_service.dart',
    'lib/controllers/background_sites_controller.dart',
  ]) {
    assert.doesNotMatch(code(read(rel)), /TorService\.instance\.(release|syncHolders)\(/,
      `${rel} lets go of Tor on the way to the background`);
  }
});
