// A lemma restated with PROOF OMITTED is taken as given, so the gate that
// holds it to a proved twin is what keeps it sound; tlapm checks nothing
// across modules.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const proved = [
  'LEMMA Hd_site_Tap ==',
  '    ASSUME TypeOK, NEW f \\in Flows, Tap(f)',
  "    PROVE  Held_site'",
  '  BY HdRow_site_Tap_1 DEF Tap',
];
const restated = (statement) => [...statement, '  PROOF OMITTED'];

function gate(t, modules) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'formal-omitted-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const paths = Object.entries(modules).map(([name, lines]) => {
    const file = path.join(dir, `${name}.tla`);
    fs.writeFileSync(file, [`---- MODULE ${name} ----`, ...lines, '===='].join('\n'));
    return file;
  });
  const result = spawnSync('python3', [path.resolve(__dirname, '../../formal/proofs/omitted.py'), ...paths],
    { encoding: 'utf8' });
  assert.ifError(result.error);
  return result;
}

test('an omitted lemma proved word for word elsewhere passes', (t) => {
  const result = gate(t, { table: proved, steps: restated(proved.slice(0, 3)) });
  assert.equal(result.status, 0, result.stdout);
  assert.match(result.stdout, /OK: 1 omitted lemmas/);
});

test('an omitted lemma stated otherwise than where it is proved fails', (t) => {
  const weaker = [proved[0], '    ASSUME TypeOK, Held, NEW f \\in Flows, Tap(f)', proved[2]];
  const result = gate(t, { table: proved, steps: restated(weaker) });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Hd_site_Tap is omitted and stated otherwise/);
});

test('an omitted lemma no module proves fails', (t) => {
  const result = gate(t, { steps: restated(proved.slice(0, 3)) });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Hd_site_Tap is omitted and proved in no module/);
});

// A member of a set is stated on its header's line.
const oneLine = ['LEMMA Places_tap == "tap" \\in Places', '  BY Zenon DEF Places'];

test('an omitted lemma stated on its header line and proved word for word elsewhere passes', (t) => {
  const result = gate(t, { members: oneLine, types: restated(oneLine.slice(0, 1)) });
  assert.equal(result.status, 0, result.stdout);
  assert.match(result.stdout, /OK: 1 omitted lemmas/);
});

test('an omitted lemma stated on its header line that no module proves fails', (t) => {
  const result = gate(t, { types: restated(oneLine.slice(0, 1)) });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /Places_tap is omitted and proved in no module/);
});

test('an omitted lemma whose twin is omitted too fails', (t) => {
  const result = gate(t, { table: restated(proved.slice(0, 3)), steps: restated(proved.slice(0, 3)) });
  assert.equal(result.status, 1);
});
