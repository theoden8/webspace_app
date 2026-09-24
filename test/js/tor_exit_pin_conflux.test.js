// TOR-014: an exit-country pin turns conflux off in the same SETCONF.
//
// A conflux set outlives an ExitNodes change. Closing one of its legs makes
// tor launch a recovery leg with the exit the other legs already use, and a
// stream takes any linked set whose exit is not excluded, so the set goes on
// carrying pinned traffic through the pre-pin country. On a real tor a {de}
// pin left through the Netherlands and a {us} pin through Germany this way.
// With conflux off no leg links, and every stream rides a circuit built under
// the pin.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'ios/Runner/TorControllerPlugin.swift';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

function body(signature) {
  const start = src.indexOf(signature);
  assert.notEqual(start, -1, `${rel} lost ${signature}`);
  // Past the type annotation, which is itself `[[AnyHashable: Any]]`.
  const value = src.slice(start).search(/\{|=/) + start;
  const open = src.indexOf('[', value);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '[') depth++;
    if (src[i] === ']' && --depth === 0) return src.slice(open, i + 1);
  }
  throw new Error(`unterminated ${signature}`);
}

test('the pin sets ExitNodes, StrictNodes 1 and ConfluxEnabled 0 together', () => {
  const pin = body('static func exitPinConfigs(');
  assert.match(pin, /"ExitNodes"/);
  assert.match(pin, /"StrictNodes",\s*"value":\s*"1"/);
  assert.match(pin, /"ConfluxEnabled",\s*"value":\s*"0"/,
    'without conflux off, a recovering conflux set keeps its pre-pin exit');
});

test('clearing the pin gives conflux back to tor', () => {
  const clear = body('static let exitPinClearConfigs');
  assert.match(clear, /"StrictNodes",\s*"value":\s*"0"/);
  assert.match(clear, /"ConfluxEnabled",\s*"value":\s*"auto"/);
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
