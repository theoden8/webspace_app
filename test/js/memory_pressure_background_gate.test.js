// PAUSE-034: leaving the screen is not memory pressure.
//
// Flutter calls `didHaveMemoryPressure` for an OS memory warning and also on
// every exit from the screen: the iOS engine's `flutterDidEnterBackground`
// calls `notifyLowMemory`, and the Android embedding forwards
// `TRIM_MEMORY_UI_HIDDEN`. Trimming on the second kind disposed one site for
// every two trips to the home screen, notification sites included (BUG-024).
// The decision and its message ordering are unit-tested in
// test/app_lifecycle_engine_test.dart; this holds the call sites to it.

const test = require('node:test');
const assert = require('node:assert/strict');
const { findMethod, callSites } = require('./helpers/source');

test('the memory-pressure observer asks the engine before it trims', () => {
  const m = findMethod('didHaveMemoryPressure');
  const where = `${m.file}:${m.line}`;
  const gate = m.body.indexOf('AppLifecycleEngine.memoryPressureTrims(');
  assert.notEqual(gate, -1,
    `${where} must ask AppLifecycleEngine.memoryPressureTrims before trimming (PAUSE-034)`);
  const trim = m.body.indexOf('.memoryPressure(');
  assert.ok(trim > gate, `${where} trims before it asks the engine`);
  assert.match(m.body.slice(gate, trim), /\breturn\b/,
    `${where} must return when the engine says the event is not the OS asking`);
  assert.match(m.body.slice(0, trim), /lifecycleState/,
    `${where} must decide on the binding's lifecycle state at the time of the event`);
});

test('the cascade is entered only through that observer', () => {
  const sites = callSites('.memoryPressure');
  assert.deepEqual(sites.map((s) => s.file), ['lib/screens/webspace_page.dart'],
    'a second caller of memoryPressure() would trim without the PAUSE-034 gate: ' +
      sites.map((s) => `${s.file}:${s.line}`).join(', '));
});
