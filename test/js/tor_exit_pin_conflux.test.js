// TOR-014: an exit-country pin turns conflux off in the same SETCONF.
//
// A conflux set outlives an ExitNodes change. Closing one of its legs makes
// tor launch a recovery leg with the exit the other legs already use, and a
// stream takes any linked set whose exit is not excluded, so the set goes on
// carrying pinned traffic through the pre-pin country. On a real tor a {de}
// pin left through the Netherlands and a {us} pin through Germany this way.
// With conflux off no leg links, and every stream rides a circuit built under
// the pin.
//
// The circuits from before the pin are closed, and a close that did not
// happen fails the change: a kept-alive connection stays on its old circuit,
// still leaving from the old exit. Here rather than in a type because Swift
// only warns on a dropped result, and the Xcode builds do not fail on
// warnings.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, enclosed } = require('./helpers/source');

const rel = 'ios/Runner/TorControllerPlugin.swift';
const src = read(rel);

function body(signature) {
  const start = src.indexOf(signature);
  assert.notEqual(start, -1, `${rel} lost ${signature}`);
  // Past the type annotation, which is itself `[[AnyHashable: Any]]`.
  const value = src.slice(start).search(/\{|=/) + start;
  const { open, close } = enclosed(src, value, '[', rel);
  return src.slice(open, close + 1);
}

test('the pin sets ExitNodes, StrictNodes 1 and ConfluxEnabled 0 together', () => {
  const pin = body('static func exitPinConfigs(');
  assert.match(pin, /"ExitNodes"/);
  assert.match(pin, /"StrictNodes",\s*"value":\s*"1"/);
  assert.match(pin, /"ConfluxEnabled",\s*"value":\s*confluxEnabledValue/,
    'without conflux off, a recovering conflux set keeps its pre-pin exit');
  assert.match(src, /static let confluxEnabledValue = "0"/);
});

test('clearing the pin keeps conflux off (TOR-024)', () => {
  const clear = body('static let exitPinClearConfigs');
  assert.match(clear, /"StrictNodes",\s*"value":\s*"0"/);
  assert.match(clear, /"ConfluxEnabled",\s*"value":\s*confluxEnabledValue/);
});

test('the apply path uses those, and closes circuits after them', () => {
  const start = src.indexOf('private func applyExitCountry(');
  const apply = src.slice(start, src.indexOf('\n  }\n', start));
  assert.match(apply, /setConfs\(controller, Self\.exitPinClearConfigs\)/);
  const pin = apply.indexOf('Self.exitPinConfigs(exitNodes)');
  assert.notEqual(pin, -1, 'the pin must go through exitPinConfigs');
  assert.ok(apply.indexOf('closeExitCircuits(controller)', pin) > pin,
    'circuits must be closed after conflux is off, or their recovery legs can still link');
  assert.ok(!/"ExitNodes",\s*"value"/.test(apply),
    'ExitNodes is set only through exitPinConfigs, never beside it');
});

test('a change whose old circuits were not closed is not in force', () => {
  assert.match(src,
    /private func closeExitCircuits\(_ controller: TorController\) async -> FlutterError\?/,
    'closeExitCircuits must say when it could not close the old circuits');
  const start = src.indexOf('private func applyExitCountry(');
  const apply = src.slice(start, src.indexOf('\n  }\n', start));
  const calls = apply.match(/closeExitCircuits\(controller\)/g) || [];
  const used = apply.match(
    /(return await|let failed = await) closeExitCircuits\(controller\)/g) || [];
  assert.equal(calls.length, 2, 'the pin and the clear each close the old circuits');
  assert.equal(used.length, calls.length,
    'a failed close has to fail the change, not be awaited and dropped');
});
