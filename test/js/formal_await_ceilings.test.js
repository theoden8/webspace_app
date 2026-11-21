// formal/await_ceilings.py holds the awaits each input's flow takes, as the
// printer counts them off the step tables, to formal/await_ceilings.tsv: a
// ceiling only falls. verify.sh also runs it on a printed copy of the tables
// with one more await on Tap's flow, which must fail; these cases hold the
// gate's own rules.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const gate = path.resolve(__dirname, '../../formal/await_ceilings.py');

function run(t, { ceilings, printed, planted }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'await-ceilings-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const want = path.join(dir, 'ceilings.tsv');
  const got = path.join(dir, 'printed.tsv');
  fs.writeFileSync(want, `# input\tawaits\tloops\n${ceilings.join('\n')}\n`);
  fs.writeFileSync(got, `# input\tawaits\tloops\tpath\n${printed.join('\n')}\n`);
  const out = path.join(dir, 'out.tsv');
  const args = ['-I', gate, want, got, '--out', out];
  if (planted) {
    const plant = path.join(dir, 'planted.tsv');
    fs.writeFileSync(plant, `${planted.join('\n')}\n`);
    args.push('--planted', plant);
  }
  const result = spawnSync('python3', args, { encoding: 'utf8' });
  return { result, out };
}

test('the printed counts at their ceilings pass', (t) => {
  const { result, out } = run(t, {
    ceilings: ['Tap\t24\tnav:12', 'GoHome\t4\t-'],
    printed: ['Tap\t24\tnav:12\tnav exit', 'GoHome\t4\t-\thCap'],
  });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(fs.readFileSync(out, 'utf8'), /^Tap\t24\tnav:12$/m);
});

test('a flow that takes one more await fails', (t) => {
  const { result } = run(t, { ceilings: ['Tap\t24\t-'], printed: ['Tap\t25\t-\tnav'] });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /OVER Tap takes 25 awaits to its end, over its ceiling 24/);
});

test('a loop that takes one more await a round fails', (t) => {
  const { result } = run(t, { ceilings: ['Tap\t24\tnav:12'], printed: ['Tap\t24\tnav:13\tnav'] });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /OVER Tap loops at nav with 13 awaits a round, over 12/);
});

test('a loop the ceilings do not name fails', (t) => {
  const { result } = run(t, { ceilings: ['Tap\t24\t-'], printed: ['Tap\t24\tnav:1\tnav'] });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /OVER Tap loops at nav, 1 awaits a round, which the ceilings do not name/);
});

test('an input the ceilings do not name fails, and one no table has fails', (t) => {
  const { result } = run(t, { ceilings: ['Tap\t1\t-'], printed: ['Wake\t1\t-\twAsk'] });
  assert.equal(result.status, 1);
  assert.match(result.stdout, /OVER Tap is in the ceilings but no input of the tables/);
  assert.match(result.stdout, /OVER Wake is an input the ceilings do not name/);
});

test('a ceiling that fell passes and asks for the lower count to be committed', (t) => {
  const { result } = run(t, { ceilings: ['Tap\t24\tnav:12'], printed: ['Tap\t23\t-\tnav'] });
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /a ceiling fell \(Tap Tap@nav\): commit the printed counts/);
});

test('the tables with one more await are caught, and a plant that passes fails the gate', (t) => {
  const caught = run(t, {
    ceilings: ['Tap\t24\t-'], printed: ['Tap\t24\t-\tnav'], planted: ['Tap\t25\t-\tnav'],
  });
  assert.equal(caught.result.status, 0, caught.result.stdout + caught.result.stderr);
  assert.match(caught.result.stdout, /OK {3}planted: one more await is caught \(Tap\)/);
  const vacuous = run(t, {
    ceilings: ['Tap\t24\t-'], printed: ['Tap\t24\t-\tnav'], planted: ['Tap\t24\t-\tnav'],
  });
  assert.equal(vacuous.result.status, 1);
  assert.match(vacuous.result.stderr, /the tables with one more await passed, so the gate is vacuous/);
});
